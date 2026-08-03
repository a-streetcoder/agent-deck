import Foundation

// MARK: - Scan refresh & launch resource fingerprints

extension AppViewModel {
    func refresh(includeModels: Bool = false, scanAllProjects: Bool = false, extraProjectPathsToScan: Set<String> = [], silentlyReconcile: Bool = false) {
        let selectedProjectPath = selectedProjectPath
        let shouldScanAllProjects = scanAllProjects
        let preferencesByPath = projectPreferencesStore.preferencesByPath
        let rootURLs = configuredProjectsRootURLs
        let externalSkillPaths = appSettings.externalSkillPaths
        let externalPromptPaths = appSettings.externalPromptPaths
        let codexPluginSkillReferences = appSettings.codexPluginSkillReferences
        let skillCollectionNames = Set(appSettings.skillCollections.map(\.name))
        refreshRequestID += 1
        let requestID = refreshRequestID
        if !silentlyReconcile {
            isRefreshingProjects = true
        }

        refreshTask?.cancel()
        let viewModel = self
        // `.utility`, not the default (which escalates to user-interactive QoS): a
        // filesystem project scan must NOT outrank the main thread, or it starves the
        // UI for CPU during scroll/interaction (a ~280ms scroll hang traced to
        // `discoverProjects` running at user-interactive QoS).
        refreshTask = Task.detached(priority: .utility) {
            let result = AppRefreshService().loadSnapshot(
                rootURLs: rootURLs,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: preferencesByPath,
                externalSkillPaths: externalSkillPaths,
                externalPromptPaths: externalPromptPaths,
                codexPluginSkillReferences: codexPluginSkillReferences,
                skillCollectionNames: skillCollectionNames,
                scanAllProjects: shouldScanAllProjects,
                extraProjectPathsToScan: extraProjectPathsToScan
            )

            await MainActor.run {
                guard !Task.isCancelled, requestID == viewModel.refreshRequestID else { return }
                viewModel.applyRefreshSnapshot(
                    result,
                    includeModels: includeModels
                )
                // Always clear in completion — covers the case where a silent
                // refresh cancels an in-flight loud one (the loud one's
                // `isRefreshingProjects = true` would otherwise stay set
                // because its completion never runs).
                if requestID == viewModel.refreshRequestID {
                    viewModel.isRefreshingProjects = false
                }
            }
        }
    }

    // Blocks the main thread on a full project rescan. Only `refreshAfterOverrideChange`
    // should reach for this: builtin-override toggles are bound to snapshot-derived UI
    // state, and an async refresh would let the toggle snap back to the old value for a
    // frame while the rescan is in flight. Every other caller should use `refresh(...)`
    // (which is detached) and rely on `silentlyReconcile: true` to avoid the spinner.
    func refreshSynchronouslyBlocksMainUntilDone(
        includeModels: Bool = false,
        scanAllProjects: Bool = false,
        extraProjectPathsToScan: Set<String> = []
    ) {
        let result = AppRefreshService().loadSnapshot(
            rootURLs: configuredProjectsRootURLs,
            selectedProjectPath: selectedProjectPath,
            preferencesByPath: projectPreferencesStore.preferencesByPath,
            externalSkillPaths: appSettings.externalSkillPaths,
            externalPromptPaths: appSettings.externalPromptPaths,
            codexPluginSkillReferences: appSettings.codexPluginSkillReferences,
            skillCollectionNames: Set(appSettings.skillCollections.map(\.name)),
            scanAllProjects: scanAllProjects,
            extraProjectPathsToScan: extraProjectPathsToScan
        )
        applyRefreshSnapshot(result, includeModels: includeModels)
        isRefreshingProjects = false
    }

    /// Queue a "select this skill once it shows up" intent and kick off an
    /// async refresh. Used by sheet-save flows that create a new skill —
    /// avoids the prior synchronous refresh that blocked the UI on the
    /// filesystem scan just so the next line could look up the new record's id.
    func scheduleSelectSkill(byFilePath path: String) {
        pendingSelectSkillFilePath = path
        // Already-visible record? Select it inline so the detail pane updates
        // before the rescan lands.
        if let id = allVisibleSkillRecords.first(where: { $0.filePath == path })?.id {
            selectedSkillID = id
        }
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Sibling of `scheduleSelectSkill(byFilePath:)` for prompts.
    func scheduleSelectPrompt(byFilePath path: String) {
        pendingSelectPromptFilePath = path
        if let id = allVisiblePromptTemplateRecords.first(where: { $0.filePath == path })?.id {
            selectedCommandItemID = id
        }
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Navigate to the Memory screen and select a specific record. Driven by the
    /// `.agentDeckOpenMemoryRequested` notification a transcript recall card posts
    /// when an injected memory title is tapped. Switches the project if the record
    /// lives in another one so it lands in the visible set; `MemoryScreen` consumes
    /// `selectedMemoryID`. A since-deleted id simply won't resolve — a graceful no-op.
    func openMemory(byID id: String) {
        if let record = agentMemoryStore.records.first(where: { $0.id == id }),
           let projectPath = record.projectPath,
           projectPath != selectedProjectPath {
            selectedProjectPath = projectPath
        }
        selectedSidebarItem = .memory
        selectedMemoryID = id
    }

    func applyRefreshSnapshot(
        _ result: AppRefreshSnapshot,
        includeModels: Bool
    ) {
        // Swift Observation notifies on every `=`, equal value or not. A
        // file-watch refresh frequently produces a byte-identical snapshot (the
        // catalog on disk didn't actually change), so reassigning unconditionally
        // re-evaluates the whole screen body — including the transcript's
        // itemsBuild + updateNSView — for nothing. Gate each heavy reassignment
        // on real inequality so a no-op rescan is invisible to the UI.
        if projectPreferencesByPath != result.projectPreferencesByPath {
            projectPreferencesByPath = result.projectPreferencesByPath
            projectPreferencesRevision &+= 1
        }
        // DiscoveredProject has no volatile fields (no timestamps / counts), so
        // value-equality is a true "the project list didn't change" test — a
        // session streaming its transcript never alters it.
        if discoveredProjects != result.discoveredProjects {
            discoveredProjects = result.discoveredProjects
        }
        hasCompletedInitialProjectDiscovery = true

        if !appSettings.didMigrateAgentAssignmentsFromDiscoveredFiles {
            guard result.includesAllProjectSnapshots else {
                refresh(includeModels: includeModels, scanAllProjects: true)
                return
            }
            migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: result.globalSnapshot, projectSnapshots: result.projectSnapshots)
        }

        // Merge the raw per-project snapshots FIRST so the catalog used to
        // resolve `globalSnapshot.effectiveAgents` reflects EVERY enabled
        // project — independent of which project triggered this (possibly
        // partial) refresh. Without this, a partial rescan
        // (`scanAllProjects: false`, e.g. the refresh fired by selecting a
        // project) would scope `globalSnapshot` against only the freshly-scanned
        // project, making the always-global Agents/Skills/Prompts views depend
        // on the selected project. `scopedAgentSnapshot` only rewrites
        // `effectiveAgents` (it preserves `projectAgents`/`libraryAgents`), so
        // mixing already-scoped existing snapshots with raw fresh ones here is
        // safe — the catalog only reads the preserved fields.
        let discoveredProjectPaths = Set(result.discoveredProjects.map(\.path))
        var mergedRawProjectSnapshots: [String: ScanSnapshot]
        if result.includesAllProjectSnapshots {
            mergedRawProjectSnapshots = result.projectSnapshots
                .filter { discoveredProjectPaths.contains($0.key) }
        } else {
            mergedRawProjectSnapshots = allProjectSnapshots
            mergedRawProjectSnapshots.merge(result.projectSnapshots) { _, fresh in fresh }
            mergedRawProjectSnapshots = mergedRawProjectSnapshots
                .filter { discoveredProjectPaths.contains($0.key) }
        }
        let catalogProjectSnapshots = Array(mergedRawProjectSnapshots.values)

        let newGlobalSnapshot = scopedAgentSnapshot(result.globalSnapshot, projectPath: nil, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        if globalSnapshot != newGlobalSnapshot { globalSnapshot = newGlobalSnapshot }

        // Per-project scoping: only freshly-scanned projects are re-scoped
        // (existing keep their prior effectiveAgents) and merged with the fresh
        // set — same number of `scopedAgentSnapshot` calls as before, no perf
        // change. The complete catalog above is what keeps the always-global
        // resource views stable across project selection.
        let freshProjectSnapshots = result.projectSnapshots.mapValues { projectSnapshot in
            scopedAgentSnapshot(projectSnapshot, projectPath: projectSnapshot.projectRoot, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        }
        let newAllProjectSnapshots: [String: ScanSnapshot]
        if result.includesAllProjectSnapshots {
            newAllProjectSnapshots = freshProjectSnapshots
        } else {
            var merged = allProjectSnapshots
            merged.merge(freshProjectSnapshots) { _, fresh in fresh }
            newAllProjectSnapshots = merged.filter { discoveredProjectPaths.contains($0.key) }
        }
        if allProjectSnapshots != newAllProjectSnapshots { allProjectSnapshots = newAllProjectSnapshots }
        watchedURLsForAutoRefresh = result.watchedURLs
        cachedResolvedCodexPluginSkillPaths = result.resolvedCodexPluginSkillPaths
        if result.includesWatchFingerprint {
            lastWatchFingerprint = result.watchFingerprint
        }
        updateAutoRefreshWatchList()

        if let matchingProject = result.selectedProject {
            if projectRootURL != matchingProject.url { projectRootURL = matchingProject.url }
            let newSnapshot = allProjectSnapshots[matchingProject.path]
                ?? result.selectedProjectSnapshot.map { scopedAgentSnapshot($0, projectPath: matchingProject.path, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots) }
                ?? globalSnapshot
            if snapshot != newSnapshot { snapshot = newSnapshot }
        } else {
            if projectRootURL != nil { projectRootURL = nil }
            if self.selectedProjectPath != nil {
                self.selectedProjectPath = nil
                persistSelectedProjectPath(nil)
            }
            let newSnapshot = makeAggregateSnapshot()
            if snapshot != newSnapshot { snapshot = newSnapshot }
        }

        // Keep MCP connections + catalog aligned with the active project. The call is
        // a no-op when the (mcpEnabled, project) key is unchanged, so frequent
        // file-watch refreshes don't re-spawn servers.
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)

        // A fresh snapshot is authoritative. Drop pending deletions no longer
        // present (deletion confirmed); keep IDs still present so a stale
        // in-flight refresh can't un-hide a row mid-deletion. Pruned against the
        // global catalog — the resource views are always global.
        if !pendingDeletedSkillIDs.isEmpty {
            let liveSkillIDs = Set((globalSnapshot.skills + globalSnapshot.librarySkills).map(\.id))
            pendingDeletedSkillIDs.formIntersection(liveSkillIDs)
        }
        if !pendingDeletedPromptIDs.isEmpty {
            let livePromptIDs = Set((globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates).map(\.id))
            pendingDeletedPromptIDs.formIntersection(livePromptIDs)
        }
        pruneStaleOptionalResourceAssignments()

        let currentAgentID = selectedAgentID
        let previousSelectedAgentName = currentAgentID.flatMap { cachedDisplayAgentByID[$0]?.name }
        let currentSkillID = selectedSkillID
        let currentCommandItemID = selectedCommandItemID

        selectedSkillID = allVisibleSkillRecords.contains(where: { $0.id == currentSkillID }) ? currentSkillID : allVisibleSkillRecords.first?.id
        let availablePromptIDs = Set(allVisiblePromptTemplateRecords.map(\.id))
        if availablePromptIDs.contains(currentCommandItemID ?? "") {
            selectedCommandItemID = currentCommandItemID
        } else {
            selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
        }

        // After a rename, restore skill selection onto the renamed record now
        // that the fresh snapshot exposes its new id.
        if let name = pendingSelectSkillName {
            if let id = allVisibleSkillRecords.first(where: { $0.name == name })?.id {
                selectedSkillID = id
            }
            pendingSelectSkillName = nil
        }
        // After a new skill/prompt save, switch selection onto the newly-
        // visible record. Replaces the prior synchronous-refresh + manual
        // lookup at the call site, which blocked the UI on a full scan.
        if let path = pendingSelectSkillFilePath {
            if let id = allVisibleSkillRecords.first(where: { $0.filePath == path })?.id {
                selectedSkillID = id
            }
            pendingSelectSkillFilePath = nil
        }
        if let path = pendingSelectPromptFilePath {
            if let id = allVisiblePromptTemplateRecords.first(where: { $0.filePath == path })?.id {
                selectedCommandItemID = id
            }
            pendingSelectPromptFilePath = nil
        }

        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions

        if includeModels {
            refreshAvailableModels()
        }

        rebuildWarningCaches()
        reconcileSelectedAgentAfterDisplayCacheRebuild(previousID: currentAgentID, previousName: previousSelectedAgentName)
        // Agent display records are cache-backed; perform pending name restore
        // after `rebuildWarningCaches()` so the lookup sees the fresh IDs.
        if let name = pendingSelectAgentName {
            if let id = filteredAgents.first(where: { $0.name == name })?.id {
                selectedAgentID = id
            }
            pendingSelectAgentName = nil
        }
        self.reconcileRunningSessionLaunchResourceFingerprints()
        hasCompletedInitialRefresh = true
    }

    func reconcileRunningSessionLaunchResourceFingerprints() {
        launchResourceFingerprintTask?.cancel()
        let runningSessions = piAgentSessionStore.sessions.filter { piAgentRunner.isRunning(sessionID: $0.id) }
        guard !runningSessions.isEmpty else {
            launchResourceFingerprintsBySessionID.removeAll()
            return
        }
        launchResourceFingerprintTask = Task { @MainActor [weak self] in
            var fresh: [UUID: String] = [:]
            for session in runningSessions {
                guard let self, !Task.isCancelled else { return }
                fresh[session.id] = await self.launchResourceFingerprint(for: session)
            }
            guard let self, !Task.isCancelled else { return }
            for session in runningSessions where self.piAgentRunner.isRunning(sessionID: session.id) {
                guard let fingerprint = fresh[session.id] else { continue }
                if let previous = self.launchResourceFingerprintsBySessionID[session.id], previous != fingerprint {
                    self.piAgentRunner.requestLaunchResourceRelaunch(
                        sessionID: session.id,
                        summary: "launch resources changed"
                    )
                }
                self.launchResourceFingerprintsBySessionID[session.id] = fingerprint
            }
            self.launchResourceFingerprintsBySessionID = self.launchResourceFingerprintsBySessionID.filter { id, _ in
                self.piAgentRunner.isRunning(sessionID: id)
            }
        }
    }

    func recordCurrentLaunchResourceFingerprint(sessionID: UUID) async {
        guard piAgentRunner.isRunning(sessionID: sessionID),
              let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        launchResourceFingerprintsBySessionID[sessionID] = await launchResourceFingerprint(for: session)
    }

    func launchResourceFingerprint(for session: PiAgentSessionRecord) async -> String {
        let projectURL = session.launchWorkingDirectory
        var parts: [String] = [
            "sessionKind=\(session.kind.rawValue)",
            "project=\(projectURL.standardizedFileURL.path)",
            "subagentsEnabled=\(session.subagentsEnabled)",
            "mcpEnabled=\(appSettings.mcpEnabled)",
            "memoryEnabled=\(appSettings.agentMemoryEnabled)",
            "memoryRecallCompleted=\(session.memoryRecallCompleted)",
            "recalledMemoryPrompt=\(session.recalledMemoryPrompt ?? "")"
        ]
        var resourcePaths: [String] = []
        if !session.isNoProject {
            resourcePaths.append(contentsOf: launchSystemPromptResourcePaths(projectURL: projectURL))
            let packageArgs = PiAgentLaunchArgumentBuilder.packageExtensionArguments(
                settings: appSettings,
                projectURL: projectURL
            )
            let extensionArgs = PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
                settings: appSettings,
                projectURL: projectURL
            )
            parts.append("packageArgs=\(packageArgs.joined(separator: "\u{1f}"))")
            parts.append("extensionArgs=\(extensionArgs.joined(separator: "\u{1f}"))")
            resourcePaths.append(contentsOf: launchResourcePaths(in: packageArgs + extensionArgs, flags: ["--extension"]))
        }

        if let boundAgent = boundAgent(for: session) {
            parts.append("boundAgent=\(boundAgent.name)")
            parts.append("boundAgentPrompt=\(boundAgent.resolved.systemPrompt)")
            parts.append("boundAgentSkills=\(boundAgent.resolved.skills.sorted().joined(separator: ","))")
            if let sourcePath = boundAgent.sourcePath {
                resourcePaths.append(sourcePath)
            }
            if let args = try? boundAgentSkillArguments(for: boundAgent) {
                parts.append("boundAgentSkillArgs=\(args.joined(separator: "\u{1f}"))")
                resourcePaths.append(contentsOf: launchResourcePaths(in: args, flags: ["--skill"]))
            }
        } else if !session.isNoProject {
            if let args = try? parentSkillArguments(for: projectURL) {
                parts.append("skillArgs=\(args.joined(separator: "\u{1f}"))")
                resourcePaths.append(contentsOf: launchResourcePaths(in: args, flags: ["--skill"]))
            }
            if let args = try? parentPromptTemplateArguments(for: projectURL) {
                parts.append("promptTemplateArgs=\(args.joined(separator: "\u{1f}"))")
                resourcePaths.append(contentsOf: launchResourcePaths(in: args, flags: ["--prompt-template"]))
            }
            if session.subagentsEnabled, let catalog = nativeSubagentCatalogPrompt(for: session) {
                parts.append("subagentCatalog=\(catalog)")
            } else {
                parts.append("subagentCatalog=")
            }
        }

        if let catalog = await mcpCatalogPrompt(for: session) {
            parts.append("mcpCatalog=\(catalog)")
        } else {
            parts.append("mcpCatalog=")
        }

        parts.append("files=\(resourcePaths.sorted().map(fileMetadataFingerprint(path:)).joined(separator: "\u{1e}"))")
        return parts.joined(separator: "\u{1d}")
    }

    func launchSystemPromptResourcePaths(projectURL: URL) -> [String] {
        let project = projectURL.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var paths: [String] = [
            project.appendingPathComponent(".pi", isDirectory: true).appendingPathComponent("SYSTEM.md").path,
            home.appendingPathComponent(".pi", isDirectory: true).appendingPathComponent("agent", isDirectory: true).appendingPathComponent("SYSTEM.md").path,
            project.appendingPathComponent(".pi", isDirectory: true).appendingPathComponent("APPEND_SYSTEM.md").path,
            home.appendingPathComponent(".pi", isDirectory: true).appendingPathComponent("agent", isDirectory: true).appendingPathComponent("APPEND_SYSTEM.md").path
        ]
        let contextNames = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
        paths.append(contentsOf: contextNames.map {
            home.appendingPathComponent(".pi", isDirectory: true).appendingPathComponent("agent", isDirectory: true).appendingPathComponent($0).path
        })
        var cursor: URL? = project
        while let directory = cursor {
            paths.append(contentsOf: contextNames.map { directory.appendingPathComponent($0).path })
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            cursor = parent
        }
        return Array(Set(paths))
    }

    func launchResourcePaths(in arguments: [String], flags: Set<String>) -> [String] {
        var paths: [String] = []
        for index in arguments.indices where flags.contains(arguments[index]) {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { continue }
            paths.append(arguments[valueIndex])
        }
        return paths
    }

    func fileMetadataFingerprint(path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]) else {
            return "\(url.path)#missing"
        }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? -1
        return "\(url.path)#\(values.isDirectory == true ? "dir" : "file")#\(size)#\(modified)"
    }

    /// Remove optional skill/prompt assignments whose catalog records vanished
    /// outside Agent Deck. Required dependencies (agents, loop roles, agent
    /// frontmatter skills/MCP) are intentionally left alone.
    func pruneStaleOptionalResourceAssignments() {
        let availableSkillNames = Set((globalSnapshot.skills + globalSnapshot.librarySkills).map(\.name))
        let availablePromptNames = Set((globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates).map { PiPromptTemplateLaunchResolver.normalizedNames([$0.name]).first ?? $0.name })
        var settingsChanged = false
        var projectAssignmentsChanged = false

        for name in appSettings.defaultSkillNames where !availableSkillNames.contains(name) {
            settingsChanged = appSettingsController.setDefaultSkill(name, enabled: false) || settingsChanged
        }
        for name in appSettings.defaultPromptTemplateNames {
            let normalized = PiPromptTemplateLaunchResolver.normalizedNames([name]).first ?? name
            if !availablePromptNames.contains(normalized) {
                settingsChanged = appSettingsController.setDefaultPromptTemplate(name, enabled: false) || settingsChanged
            }
        }

        for (projectPath, preference) in projectPreferencesStore.preferencesByPath {
            for name in preference.assignedSkillNames where !availableSkillNames.contains(name) {
                projectPreferencesStore.setAssignedSkill(name, assigned: false, for: projectPath)
                projectAssignmentsChanged = true
            }
            for name in preference.assignedPromptTemplateNames {
                let normalized = PiPromptTemplateLaunchResolver.normalizedNames([name]).first ?? name
                if !availablePromptNames.contains(normalized) {
                    projectPreferencesStore.setAssignedPromptTemplate(name, assigned: false, for: projectPath)
                    projectAssignmentsChanged = true
                }
            }
        }

        if settingsChanged {
            appSettings = appSettingsController.settings
        }
        if projectAssignmentsChanged {
            projectPreferencesByPath = projectPreferencesStore.preferencesByPath
            projectPreferencesRevision &+= 1
        }
    }

    /// Re-derive snapshot-scoped state from the already-cached raw snapshots
    /// after an assignment-preference change. No disk I/O: project assignment
    /// only mutates UserDefaults, and `scopedAgentSnapshot` is idempotent over
    /// the agent-catalog fields it copies through. This replaces a full
    /// `refresh()` (which re-walks the filesystem) for assignment toggles.
    func reconcileSnapshotsFromPreferences() {
        // Capture the selected agent before rebuilding the display cache,
        // because its EffectiveAgentRecord.id can change when it moves between
        // catalog-only and effective (e.g. global/project assignment toggle).
        let previousSelectedAgentID = selectedAgentID
        let previousSelectedAgentName = selectedAgent?.name
        let catalogProjectSnapshots = Array(allProjectSnapshots.values)
        globalSnapshot = scopedAgentSnapshot(
            globalSnapshot,
            projectPath: nil,
            globalCatalogSnapshot: globalSnapshot,
            catalogProjectSnapshots: catalogProjectSnapshots
        )
        allProjectSnapshots = allProjectSnapshots.mapValues { projectSnapshot in
            scopedAgentSnapshot(
                projectSnapshot,
                projectPath: projectSnapshot.projectRoot,
                globalCatalogSnapshot: globalSnapshot,
                catalogProjectSnapshots: catalogProjectSnapshots
            )
        }
        if let path = selectedProjectPath, let scoped = allProjectSnapshots[path] {
            snapshot = scoped
        } else if selectedProjectPath == nil {
            snapshot = makeAggregateSnapshot()
        }
        rebuildWarningCaches()
        reconcileSelectedAgentAfterDisplayCacheRebuild(previousID: previousSelectedAgentID, previousName: previousSelectedAgentName)
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func reconcileSelectedAgentAfterDisplayCacheRebuild(previousID: EffectiveAgentRecord.ID?, previousName: String?) {
        if let previousID, filteredAgents.contains(where: { $0.id == previousID }) {
            selectedAgentID = previousID
            return
        }
        if let previousName, let remappedID = filteredAgents.first(where: { $0.name == previousName })?.id {
            selectedAgentID = remappedID
            return
        }
        // If there was a real selection before the rebuild and the same logical
        // agent is temporarily unresolved, do not select an unrelated first row.
        // The list mirror will keep its local highlight until the next snapshot
        // either remaps the agent or the selection is intentionally cleared.
        if previousID != nil || previousName != nil {
            return
        }
        selectedAgentID = filteredAgents.first?.id
    }

}
