import Foundation

// MARK: - Warning caches & project recaps

extension AppViewModel {
    func rebuildWarningCaches() {
        // Rebuild the agent-display cache first — the warning computations below
        // read `filteredAgents`, which derives from `allDisplayAgents`.
        cachedAllDisplayAgents = computeAllDisplayAgents()
        cachedDisplayAgentByID = Dictionary(uniqueKeysWithValues: cachedAllDisplayAgents.map { ($0.id, $0) })
        cachedAgentSearchHaystackByID = Dictionary(uniqueKeysWithValues: cachedAllDisplayAgents.map { ($0.id, agentSearchHaystack(for: $0)) })
        displayAgentsRevision &+= 1
        rebuildVisibleSkillRecordCachesIfNeeded()

        let skillWarnings = buildSkillWarnings()
        let promptWarnings = buildPromptWarnings()
        let visibilityIssuesByAgentID = buildSkillVisibilityIssuesByAgentID()
        let agentNamesByID = Dictionary(uniqueKeysWithValues: filteredAgents.map { ($0.id, $0.name) })
        let skillReferenceWarnings: [SkillReferenceWarning] = visibilityIssuesByAgentID
            .flatMap { pair -> [SkillReferenceWarning] in
                guard let agentName = agentNamesByID[pair.key] else { return [] }
                return pair.value.flatMap { issue in
                    issue.missingSkills.map { missingSkill in
                        SkillReferenceWarning(agentName: agentName, project: issue.project, missingSkill: missingSkill)
                    }
                }
            }
            .sorted(by: {
                if $0.missingSkill != $1.missingSkill { return $0.missingSkill < $1.missingSkill }
                if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
                return $0.project.name < $1.project.name
            })

        // Per-agent warnings — computed once here instead of O(agents × warnings)
        // on every AgentsScreen body eval. Every filtered agent gets an entry
        // (possibly empty), so a cache hit in `warnings(for:)` is authoritative.
        var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
        for agent in filteredAgents {
            agentWarningsByID[agent.id] = computeWarnings(for: agent)
        }

        // Per-skill list metadata — computed once here instead of
        // O(skills × warnings/projects/agents) on every SkillsScreen body eval.
        // Also collects the matching warnings per skill so the detail pane
        // doesn't re-run the four string-contains checks across `skillWarnings`
        // on every render.
        var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
        var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
        // Resource catalog is always global; "active" = globally enabled (the
        // global-view definition), independent of `selectedProjectPath`.
        let activeProject: DiscoveredProject? = nil
        for record in allVisibleSkillRecords {
            let matchingWarnings = skillWarnings.filter { warning in
                warning.id == "duplicate-skill:\(record.name)" ||
                warning.id.contains(record.filePath) ||
                warning.message.contains("`\(record.name)`") ||
                warning.message.contains(record.filePath)
            }
            let hasWarnings = !matchingWarnings.isEmpty
            warningsBySkillID[record.id] = matchingWarnings
            let globallyEnabled = skillIsEnabledGlobally(record)
            let isAssigned = globallyEnabled ||
                !assignedProjects(for: record).isEmpty ||
                !assignedAgents(for: record).isEmpty
            let isActive = globallyEnabled ||
                (activeProject.map { skill(record, isEnabledFor: $0) } ?? false)
            skillMetadataByID[record.id] = SkillListMetadata(
                isAssigned: isAssigned,
                hasWarnings: hasWarnings,
                isActiveForCurrentProject: isActive,
                isImported: isImportedSkill(record)
            )
        }

        cachedSkillWarnings = skillWarnings
        cachedPromptWarnings = promptWarnings
        cachedSkillVisibilityIssuesByAgentID = visibilityIssuesByAgentID
        cachedSkillReferenceWarnings = skillReferenceWarnings
        cachedAgentWarningsByID = agentWarningsByID
        cachedSkillMetadataByID = skillMetadataByID
        cachedWarningsBySkillID = warningsBySkillID
        cachedHasSkillWarnings = !skillReferenceWarnings.isEmpty || !skillWarnings.isEmpty
        cachedHasPromptWarnings = !promptWarnings.isEmpty
        cachedHasAgentWarnings = agentWarningsByID.values.contains { !$0.isEmpty }
            || visibilityIssuesByAgentID.values.contains { !$0.isEmpty }
    }

    func buildSkillWarnings() -> [DiagnosticWarning] {
        let baseWarnings = globalSnapshot.warnings.filter { warning in
            warning.id.hasPrefix("malformed-skill:") || warning.message.localizedCaseInsensitiveContains("skill")
        }
        let collisionWarnings = PiSkillLaunchResolver.collisions(in: allVisibleSkillRecords).map { collision in
            let paths = collision.skills.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-skill:\(collision.name)", message: "Duplicate skill name `\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    func buildPromptWarnings() -> [DiagnosticWarning] {
        let baseWarnings = globalSnapshot.warnings.filter { warning in
            warning.id.hasPrefix("duplicate-prompt:")
        }
        let collisionWarnings = PiPromptTemplateLaunchResolver.collisions(in: allVisiblePromptTemplateRecords).map { collision in
            let paths = collision.prompts.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-prompt-template:\(collision.name)", message: "Duplicate prompt template name `/\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    func buildSkillVisibilityIssuesByAgentID() -> [String: [AgentSkillVisibilityIssue]] {
        var issuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
        for agent in filteredAgents {
            guard !agent.resolved.skills.isEmpty else { continue }
            let explicitSkills = agent.resolved.skills
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !explicitSkills.isEmpty else { continue }

            let managedRecord = globalSnapshot.libraryAgents.first { $0.name == agent.name }
                ?? agent.globalCustom
                ?? agent.projectCustom
            guard let managedRecord else { continue }

            let issues: [AgentSkillVisibilityIssue] = assignedProjects(for: managedRecord).compactMap { project in
                // Match child launch resolution, which uses the centralized runtime
                // catalog rather than a potentially stale per-project scan snapshot.
                let missingSkills = PiSkillLaunchResolver.unresolvedNames(
                    explicitSkills,
                    catalog: skillCatalog(forProjectPath: project.path),
                    additionalResolvableNames: Set(appSettings.skillCollections.map(\.name))
                )
                guard !missingSkills.isEmpty else { return nil }
                return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
            }
            if !issues.isEmpty {
                issuesByAgentID[agent.id] = issues
            }
        }
        return issuesByAgentID
    }



    /// skills. Synchronous config read — call on a tap, not a hot path.
    func mcpRecap(for project: DiscoveredProject) -> ProjectMcpServerRecap {
        let defaultNames = appSettings.defaultMcpServerNames
        let projectNames = projectPreference(for: project.path).assignedMcpServerNames.subtracting(defaultNames)
        let entries = MCPConfigLoader().load(projectRoot: URL(fileURLWithPath: project.path)).servers
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        func resolve(_ names: Set<String>) -> ([MCPServerRecapItem], [String]) {
            var items: [MCPServerRecapItem] = []
            var unresolved: [String] = []
            for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if let entry = byName[name] {
                    items.append(MCPServerRecapItem(name: name, detail: Self.mcpServerDetail(entry.config)))
                } else {
                    unresolved.append(name)
                }
            }
            return (items, unresolved)
        }

        let defaultResult = resolve(defaultNames)
        let projectResult = resolve(projectNames)
        return ProjectMcpServerRecap(
            defaultServers: defaultResult.0,
            projectServers: projectResult.0,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    /// A short transport/endpoint summary for an MCP server config.
    static func mcpServerDetail(_ config: MCPServerConfig) -> String? {
        switch config.resolvedTransport {
        case .stdio:
            guard let command = config.command, !command.isEmpty else { return "Local" }
            return "Local · \(command)"
        case .http, .sse:
            guard let url = config.url, !url.isEmpty else { return "Remote" }
            let host = URL(string: url)?.host(percentEncoded: false) ?? url
            return "Remote · \(host)"
        }
    }

    func agentRecap(for project: DiscoveredProject) -> ProjectAgentRecap {
        let defaultNames = appSettings.defaultAgentNames
        let projectNames = projectPreference(for: project.path).assignedAgentNames.subtracting(defaultNames)
        let effectiveAgents = (allProjectSnapshots[project.path]?.effectiveAgents ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let effectiveByName = Dictionary(uniqueKeysWithValues: effectiveAgents.map { ($0.name, $0) })

        func resolvedAgents(for names: Set<String>) -> ([EffectiveAgentRecord], [String]) {
            var agents: [EffectiveAgentRecord] = []
            var unresolved: [String] = []
            for name in names.sorted() {
                if let agent = effectiveByName[name] {
                    agents.append(agent)
                } else {
                    unresolved.append(name)
                }
            }
            return (agents, unresolved)
        }

        let defaultResult = resolvedAgents(for: defaultNames)
        let projectResult = resolvedAgents(for: projectNames)
        let highlightedNames = Set(defaultResult.0.map(\.name)).union(projectResult.0.map(\.name))
        let otherEffectiveAgents = effectiveAgents.filter { !highlightedNames.contains($0.name) }
        return ProjectAgentRecap(
            defaultAgents: defaultResult.0,
            projectAgents: projectResult.0,
            otherEffectiveAgents: otherEffectiveAgents,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }



    /// parent session is launched with (`parentPromptTemplateArguments`).

}
