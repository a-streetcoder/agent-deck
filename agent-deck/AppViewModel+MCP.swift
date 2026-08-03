import AppKit
import Foundation

// MARK: - MCP bridge / OAuth / assignment

extension AppViewModel {
    // MARK: - MCP bridge

    static let mcpCatalogToolCap = 60

    /// Reloads `mcp.json`, reconnects the manager, and rebuilds the cached catalog when
    /// the (mcpEnabled, project) key changes. No-op otherwise so file-watch refreshes
    /// don't churn server processes. Pass `forced: true` after the user edits config.
    func refreshMCPConfigurationIfNeeded(projectURL: URL?, forced: Bool = false) {
        let enabled = appSettings.mcpEnabled
        let key = "\(enabled)#\(projectURL?.path ?? "")"
        if !forced, key == mcpLastRefreshKey { return }
        mcpLastRefreshKey = key
        let token = mcpRefreshCoordinator.begin()
        mcpRefreshTask?.cancel()

        mcpRefreshTask = Task { [weak self] in
            guard let self else { return }
            // Bind OAuth token resolution so remote (http) transports authorize.
            await self.mcpConnectionManager.setAuthTokenProvider { server in
                await MCPOAuthService.shared.accessToken(for: server)
            }
            async let configuredTask = Task.detached(priority: .utility) { MCPConfigLoader().load(projectRoot: projectURL).servers }.value
            let configured = await configuredTask
            guard !Task.isCancelled, self.mcpRefreshCoordinator.isCurrent(token) else { return }

            self.mcpCatalogRevision &+= 1
            let merged = configured.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.mergedMCPEntries = merged
            self.mcpConfiguredServerNames = Set(merged.map(\.name))
            guard enabled else {
                guard await self.mcpRefreshCoordinator.configureIfCurrent(token, servers: [], manager: self.mcpConnectionManager),
                      !Task.isCancelled else { return }
                self.mcpCatalogSnapshot = []
                self.reconcileRunningSessionLaunchResourceFingerprints()
                return
            }
            guard await self.mcpRefreshCoordinator.configureIfCurrent(token, servers: merged, manager: self.mcpConnectionManager),
                  !Task.isCancelled else { return }
            // Connect/enumerate ONLY servers assigned to this project (defaults +
            // project assignment + any agent available to the project). Unassigned
            // servers stay registered but unconnected, so adding an MCP without
            // assigning it never spawns its process or triggers its permission prompt.
            let scoped = self.assignedMCPServerNames(forProjectPath: projectURL?.path)
            let catalog = await self.mcpConnectionManager.discoverCatalog(serverNames: scoped)
            guard !Task.isCancelled, self.mcpRefreshCoordinator.isCurrent(token) else { return }
            self.mcpCatalogSnapshot = catalog
            self.reconcileRunningSessionLaunchResourceFingerprints()
        }
    }

    /// Configured MCP server names available for assignment (cached; reflects the
    /// active project's merged `mcp.json`). Sorted for stable UI.
    var availableMCPServerNames: [String] { mcpConfiguredServerNames.sorted() }

    /// Probes a server (connect + list tools) for the management UI's test button.
    func probeMCPServer(_ entry: MCPServerEntry) async -> MCPProbeResult {
        await mcpConnectionManager.probe(entry: entry)
    }

    /// Tools already discovered for a server (no connection opened), so the management
    /// view can show a health pill from cache instead of reconnecting on entry.
    func cachedMCPTools(_ name: String) async -> [MCPProbeTool]? {
        await mcpConnectionManager.cachedTools(server: name)?
            .map { MCPProbeTool(name: $0.name, description: $0.description) }
    }

    /// Whether a live (reused) connection to this server already exists.
    func mcpServerHasLiveConnection(_ name: String) async -> Bool {
        await mcpConnectionManager.hasLiveConnection(name)
    }

    /// Tears down all MCP connections. Called at app termination.
    func shutdownMCP() async {
        await mcpConnectionManager.shutdown()
    }

    // MARK: MCP OAuth (per-server Connect / Sign out)

    /// Runs the OAuth Connect flow for a remote server (opens the browser). Returns an
    /// error message on failure, or nil on success.
    func connectMCPServer(_ entry: MCPServerEntry) async -> String? {
        configureMCPBrandIcon()
        guard let url = entry.config.url, !url.isEmpty else { return "This server has no URL to connect to." }
        do {
            try await MCPOAuthService.shared.connect(serverName: entry.name, serverURLString: url)
            refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
            return nil
        } catch {
            return (error as? MCPError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Signs out a remote server (drops stored tokens).
    func disconnectMCPServer(_ name: String) async {
        await MCPOAuthService.shared.disconnect(serverName: name)
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }

    /// Whether a remote server currently has stored OAuth tokens.
    func mcpServerIsConnected(_ name: String) async -> Bool {
        await MCPAuthStore.shared.isConnected(name)
    }

    /// Renders the app icon to a small base64 PNG once, so the OAuth loopback success
    /// page can show the brand mark. Idempotent; run lazily only when OAuth is starting
    /// so startup/file-watch refreshes don't spend main-thread time encoding the icon.
    func configureMCPBrandIcon() {
        guard MCPLoopbackServer.brandIconDataURI == nil else { return }
        guard let icon = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) else { return }
        let size = NSSize(width: 96, height: 96)
        let resized = NSImage(size: size)
        resized.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        MCPLoopbackServer.brandIconDataURI = "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// Whether a discovered server can be edited/removed in-app. Only the app-owned
    /// `~/.pi/agent/mcp.json` is writable; servers from project files or ~/.config/mcp
    /// are shown read-only.
    func mcpServerIsEditable(_ entry: MCPServerEntry) -> Bool {
        URL(fileURLWithPath: entry.sourcePath).standardizedFileURL == MCPConfigLoader.writableConfigURL().standardizedFileURL
    }

    /// Adds or updates a server in the app-owned mcp.json, then refreshes connections.
    func upsertMCPServer(name: String, config: MCPServerConfig) throws {
        try MCPConfigWriter().upsert(name: name, config: config)
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }

    /// Removes a server from the app-owned mcp.json, prunes its assignments, then
    /// refreshes connections (the configured set genuinely changed here).
    func removeMCPServer(named name: String) throws {
        try MCPConfigWriter().remove(name: name)
        removeMCPServerReferences(named: name)
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }

    /// Drops a removed server from the All Projects default, every project
    /// assignment, and any agent's `mcpServers` frontmatter — mirroring
    /// `removeSkillReferences` so a deleted server leaves no orphaned assignments.
    func removeMCPServerReferences(named name: String) {
        appSettingsController.setDefaultMcpServer(name, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedMcpServer(name, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()

        for agent in snapshot.effectiveAgents where (agent.resolved.mcpServers ?? []).contains(name) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.mcpServers?.removeAll { $0 == name }
            if draft.config.mcpServers?.isEmpty == true { draft.config.mcpServers = nil }
            // Persist directly (no per-agent rescan); the trailing refresh in
            // removeMCPServer picks up every edit.
            try? agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
    }

    /// MCP servers in scope for a session: a bound-agent (1:1) session uses the agent's
    /// assigned servers; a project session uses the global defaults unioned with the
    /// project's assignment. Always intersected with servers that actually exist in config.
    func assignedMCPServerNames(for session: PiAgentSessionRecord) -> Set<String> {
        if session.isNoProject {
            // No-project chats never inherit project/default MCP assignments.
            return []
        }

        let resolved: Set<String>
        if let agent = boundAgent(for: session) {
            resolved = Set(agent.resolved.mcpServers ?? [])
        } else {
            var names = appSettings.defaultMcpServerNames
            if let projectPath = session.projectPathForProjectFeatures {
                names.formUnion(projectPreference(for: projectPath).assignedMcpServerNames)
            }
            resolved = names
        }
        return resolved.intersection(mcpConfiguredServerNames)
    }

    /// MCP servers worth connecting when a chat in `projectPath` is opened: the global
    /// defaults, the project's own assignment, and every server any agent available to
    /// that project assigns (so a bound-agent chat finds its tools already discovered).
    /// Intersected with the configured set. A server added but assigned to nothing
    /// (e.g. an Xcode MCP) is excluded here, so it is never connected and never prompts.
    func assignedMCPServerNames(forProjectPath projectPath: String?) -> Set<String> {
        var names = appSettings.defaultMcpServerNames
        let scopedProjectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let scopedProjectPath {
            names.formUnion(projectPreference(for: scopedProjectPath).assignedMcpServerNames)
        }
        let agents = scopedProjectPath.flatMap { allProjectSnapshots[$0]?.effectiveAgents } ?? globalSnapshot.effectiveAgents
        for agent in agents { names.formUnion(agent.resolved.mcpServers ?? []) }
        return names.intersection(mcpConfiguredServerNames)
    }

    // MARK: MCP assignment (used by the MCP servers management UI)

    /// All configured and transient plugin MCP entries for the active project. Plugin
    /// paths are only held in the current refresh result and are never written.
    func mcpServerEntries() async -> [MCPServerEntry] {
        let root = projectRootURL
        let configured = await Task.detached(priority: .utility) {
            MCPConfigLoader().load(projectRoot: root).servers
        }.value
        return configured.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func mcpServer(_ name: String, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedMcpServerNames.contains(name)
    }

    func setMcpServer(_ name: String, enabled: Bool, for project: DiscoveredProject) {
        projectPreferencesStore.setAssignedMcpServer(name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Assignment now governs which servers we actually connect, so re-run scoped
        // discovery: a newly-assigned server connects (and populates the catalog) while
        // a newly-unassigned one drops out. Connections are reused, so this only spawns
        // a server process the first time it becomes assigned.
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }

    func isMcpServerEnabledForAllProjects(_ name: String) -> Bool {
        appSettings.defaultMcpServerNames.contains(name)
    }

    func setMcpServerEnabledForAllProjects(_ name: String, enabled: Bool) {
        appSettingsController.setDefaultMcpServer(name, enabled: enabled)
        appSettings = appSettingsController.settings
        // A default assignment makes this server in-scope for every project, so re-run
        // scoped discovery to connect/enumerate it (or drop it). Connections are reused.
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }

    func setMCPEnabled(_ enabled: Bool) {
        appSettingsController.setMCPEnabled(enabled)
        appSettings = appSettingsController.settings
        refreshMCPConfigurationIfNeeded(projectURL: projectRootURL, forced: true)
    }


    /// Compact MCP tool catalog injected into the system prompt, scoped to the session's
    /// assigned servers. Returns nil when MCP is off or nothing is assigned, so neither
    /// the bridge nor a prompt block is injected (matching the Deck-agents catalog).
    ///
    /// Sessions whose project differs from the active project discover their assigned
    /// servers on demand via the connection manager instead of filtering the
    /// active-project snapshot, which only covers the active project's scope. The
    /// manager reuses live connections and caches tool lists, so a server already
    /// connected for another project adds no extra process or permission prompt.
    func mcpCatalogPrompt(for session: PiAgentSessionRecord) async -> String? {
        guard appSettings.mcpEnabled else { return nil }
        let scope = assignedMCPServerNames(for: session)
        let entries = await mcpCatalogEntries(forScope: scope, projectPath: session.projectPathForProjectFeatures)
        return mcpCatalogPrompt(fromEntries: entries, scope: scope)
    }

    /// Resolves catalog entries for a scope. When the scope belongs to a project other
    /// than the active one, discovers on demand via the connection manager (reusing
    /// live connections and cached tool lists) instead of relying on the
    /// active-project snapshot, which only covers the active project's assigned servers.
    /// Relies on the servers being in the manager's configured set; globally configured
    /// servers (the common case) are always present regardless of active project.
    private func mcpCatalogEntries(forScope scope: Set<String>, projectPath: String?) async -> [MCPCatalogEntry] {
        guard !scope.isEmpty else { return [] }
        // `nil == nil` must not select the active-project cache: a no-project
        // session has its own capability-only scope and must discover that scope
        // directly rather than inheriting any cached project catalog.
        if let projectPath, projectPath == projectRootURL?.path {
            return mcpCatalogSnapshot.filter { scope.contains($0.server) }
        }
        return await mcpConnectionManager.discoverCatalog(serverNames: scope)
    }

    /// MCP servers in scope for a delegated Deck agent: its assigned `mcpServers`,
    /// intersected with the configured set (mirrors the bound-agent branch of
    /// `assignedMCPServerNames`).
    func subagentMCPScope(parentSessionID: UUID, agentName: String?) -> Set<String> {
        guard let agentName,
              let parent = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else { return [] }
        let projectPath = parent.projectPathForProjectFeatures
        let agent = (projectPath.flatMap { allProjectSnapshots[$0]?.effectiveAgents } ?? globalSnapshot.effectiveAgents)
            .first { $0.name == agentName }
            ?? projectPath.flatMap { selectableAgentUniverse(forProjectPath: $0).first { $0.name == agentName } }
        return Set(agent?.resolved.mcpServers ?? []).intersection(mcpConfiguredServerNames)
    }

    /// Launch arguments injecting the native MCP bridge + a scoped catalog into a
    /// delegated Deck agent, so an agent's assigned `mcpServers` work under delegation
    /// exactly as they do in a 1:1 bound chat. Returns `[]` when MCP is off or the agent
    /// has no in-scope servers (no bridge, no prompt block — like the parent path).
    func childMCPArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord) async -> [String] {
        guard appSettings.mcpEnabled else { return [] }
        let scope = Set(agent.resolved.mcpServers ?? []).intersection(mcpConfiguredServerNames)
        let entries = await mcpCatalogEntries(forScope: scope, projectPath: parentSession.projectPathForProjectFeatures)
        guard let catalog = mcpCatalogPrompt(fromEntries: entries, scope: scope), !catalog.isEmpty,
              let mcpURL = try? PiNativeSubagentBridgeExtensions.mcpExtensionURL() else { return [] }
        return ["--extension", mcpURL.path, "--append-system-prompt", catalog]
    }

    func handleSubagentMCPBridge(parentSessionID: UUID, runID: UUID, agentName: String?, request: PiMCPBridgeRequest) async -> String {
        await performMCPBridge(request: request, scope: subagentMCPScope(parentSessionID: parentSessionID, agentName: agentName), sessionID: parentSessionID, projectID: piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID })?.projectPathForProjectFeatures, requestingAgent: agentName, subagentRunID: runID)
    }

    /// Compact MCP tool catalog for a given set of entries. Shared by the parent-session
    /// and delegated-Deck-agent paths.
    func mcpCatalogPrompt(fromEntries entries: [MCPCatalogEntry], scope: Set<String>) -> String? {
        guard appSettings.mcpEnabled else { return nil }
        _ = scope
        let entries = entries.sorted { $0.qualifiedName < $1.qualifiedName }
        guard !entries.isEmpty else { return nil }

        var lines: [String] = [
            "MCP tools (call through the `mcp` proxy tool):",
            "- Call a tool: mcp({ tool: \"server/tool\", args: { ... } })",
            "- Discover: mcp({}) lists servers, mcp({ search: \"keywords\" }) finds tools, mcp({ describe: \"server/tool\" }) shows a tool's input schema."
        ]
        if entries.count <= Self.mcpCatalogToolCap {
            lines.append("Available MCP tools:")
            lines.append(contentsOf: entries.map { entry in
                let desc = entry.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(entry.qualifiedName): \(desc?.isEmpty == false ? desc! : "(no description)")"
            })
        } else {
            let counts = Dictionary(grouping: entries, by: \.server).mapValues(\.count)
            lines.append("Available MCP servers (use mcp({ search }) to find specific tools):")
            lines.append(contentsOf: counts.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value) tools" })
        }
        return lines.joined(separator: "\n")
    }

    /// Handles an `mcp` proxy bridge request: routes list/search/describe/call to the
    /// native connection manager, scoped to the session's assigned servers.
    func handleMCPBridge(sessionID: UUID, request: PiMCPBridgeRequest, completion: @escaping (String) -> Void) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else {
            completion("Unknown Agent Deck session; MCP access is denied.")
            return
        }
        let scope = assignedMCPServerNames(for: session)
        let boundAgentName = boundAgent(for: session)?.name
        Task { [weak self] in
            guard let self else { completion("\(AppBrand.displayName)'s MCP bridge is not available."); return }
            let text = await self.performMCPBridge(request: request, scope: scope, sessionID: sessionID, projectID: self.piAgentSessionStore.sessions.first(where: { $0.id == sessionID })?.projectPathForProjectFeatures, requestingAgent: boundAgentName)
            completion(text)
        }
    }

    static func encodeMCPBridgeCallResult(_ result: PiMCPBridgeCallResultEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(result)) ?? Data(LanguageStore.shared.t("vm.mcpBridgeEncodeFailed").utf8), as: UTF8.self)
    }

    func performMCPBridge(request: PiMCPBridgeRequest, scope: Set<String>, sessionID: UUID, projectID: String? = nil, requestingAgent: String? = nil, subagentRunID: UUID? = nil) async -> String {
        switch request.action {
        case "search":
            let hits = await mcpConnectionManager.search(query: request.query ?? "", serverNames: scope)
            guard !hits.isEmpty else { return "No MCP tools matched \"\(request.query ?? "")\"." }
            return hits.map { "- \($0.qualifiedName): \($0.description ?? "(no description)")" }.joined(separator: "\n")

        case "describe":
            guard let address = MCPConnectionManager.resolveAddress(request.tool ?? "", serverHint: request.server),
                  scope.contains(address.server) else {
                return "Unknown or unassigned MCP tool \"\(request.tool ?? "")\"."
            }
            guard let descriptor = await mcpConnectionManager.describe(server: address.server, tool: address.tool) else {
                return "Tool \(address.server)/\(address.tool) was not found."
            }
            var out = "\(address.server)/\(descriptor.name): \(descriptor.description ?? "(no description)")"
            if let schema = descriptor.inputSchema, let json = Self.prettyJSON(schema) {
                out += "\nInput schema:\n\(json)"
            }
            return out

        case "call":
            guard let address = MCPConnectionManager.resolveAddress(request.tool ?? "", serverHint: request.server) else {
                return "Specify a tool as \"server/tool\"."
            }
            guard scope.contains(address.server) else {
                return "MCP server \"\(address.server)\" is not assigned to this session."
            }
            do {
                let result = try await mcpConnectionManager.call(server: address.server, tool: address.tool, arguments: request.args, context: MCPCallContext(sessionID: sessionID, projectID: projectID, server: address.server, tool: address.tool, requestingAgent: requestingAgent, subagentRunID: subagentRunID))
                return Self.encodeMCPBridgeCallResult(.callResult(result, server: address.server, tool: address.tool))
            } catch {
                return Self.encodeMCPBridgeCallResult(.failure(server: address.server, tool: address.tool, message: LanguageStore.shared.t("vm.mcpCallFailed", error.localizedDescription)))
            }

        default: // "list"
            let entries = mcpCatalogSnapshot.filter { scope.contains($0.server) }
            guard !entries.isEmpty else { return LanguageStore.shared.t("vm.noMcpServersAssigned") }
            let counts = Dictionary(grouping: entries, by: \.server).mapValues(\.count)
            return counts.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value) tools" }.joined(separator: "\n")
        }
    }

    static func prettyJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(decoding: pretty, as: UTF8.self)
    }

}
