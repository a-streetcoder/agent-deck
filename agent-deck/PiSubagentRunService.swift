import Foundation

/// Captures the specific `PiRPCClient` that owns a run's process so the run
/// service can tell a stale client's late termination apart from the current
/// client's termination. See `PiSubagentRunService.handleTermination`.
@MainActor
final class ClientTerminationHolder {
    weak var client: PiRPCClient?
}

struct PiSubagentMemoryLaunchContext {
    var arguments: [String]
    var memoryIDs: [String]?
    var memoryTitles: [String]?

    static let empty = PiSubagentMemoryLaunchContext(arguments: [], memoryIDs: nil, memoryTitles: nil)
}

@MainActor
final class PiSubagentRunService {
    private let store: PiAgentSessionStore
    private var clientsByRunID: [UUID: PiRPCClient] = [:]
    private var finalTextByRunID: [UUID: String] = [:]
    private var assistantEntryIDsByRunID: [UUID: UUID] = [:]
    private var assistantTextByRunID: [UUID: String] = [:]
    private var thinkingEntryIDsByRunID: [UUID: UUID] = [:]
    private var thinkingTextByRunID: [UUID: String] = [:]
    private var toolEntryIDsByCallID: [String: UUID] = [:]
    private var completionHandlersByRunID: [UUID: (PiSubagentRunRecord) -> Void] = [:]
    private var supervisorTimeoutTasksByRequestID: [String: Task<Void, Never>] = [:]
    private var streamFlushTasksByRunID: [UUID: Task<Void, Never>] = [:]
    /// On `agent_end` we request the child's session stats (for its cost) and
    /// hold off completion until the response lands or this timeout fires, so a
    /// model that never reports stats can't stall the run.
    private var pendingStatsTasksByRunID: [UUID: Task<Void, Never>] = [:]
    private let fileManager = FileManager.default
    var childMemoryArgumentsProvider: ((PiAgentSessionRecord, EffectiveAgentRecord, String) async throws -> PiSubagentMemoryLaunchContext)?
    var onMemoryWrite: ((UUID, UUID, String?, AgentMemoryWriteBridgeRequest) async -> String)?
    var onMemoryMarkStale: ((UUID, UUID, String?, AgentMemoryStaleBridgeRequest) async -> String)?
    var onMemorySearch: ((UUID, UUID, String?, AgentMemorySearchBridgeRequest) async -> String)?
    /// Expands app-managed skill collection assignments before delegated child
    /// launch. Runtime still receives individual `--skill` arguments.
    var childSkillArgumentsProvider: ((EffectiveAgentRecord, ScanSnapshot) throws -> [String])?
    /// Injects the native MCP bridge + scoped catalog into a delegated Deck agent
    /// (mirrors `childMemoryArgumentsProvider`). Returns `[]` when the agent has no
    /// assigned MCP servers or MCP is off.
    var childMCPArgumentsProvider: ((PiAgentSessionRecord, EffectiveAgentRecord) async -> [String])?
    /// Routes a delegated agent's `mcp` proxy call to the app's connection manager,
    /// scoped to that agent's assigned servers.
    var onMCPBridgeRequest: ((UUID, UUID, String?, PiMCPBridgeRequest) async -> String)?

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(runID: UUID) -> Bool {
        clientsByRunID[runID]?.isRunning == true
    }

    @discardableResult
    func runSingle(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, continueRunID: UUID? = nil, useWorktreeIsolation: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], onCompletion: ((PiSubagentRunRecord) -> Void)? = nil) async throws -> PiSubagentRunRecord {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { throw NativeSubagentError.emptyTask }
        guard agent.resolved.disabled != true else { throw NativeSubagentError.disabledAgent(agent.name) }
        guard let parentProjectPath = parentSession.projectPathForProjectFeatures else { throw NativeSubagentError.noProjectUnavailable }

        let now = Date()
        let continuingRun = try continuableRun(parentSessionID: parentSession.id, runID: continueRunID)
        let isContinuation = continuingRun != nil
        let runID = continuingRun?.id ?? UUID()
        let artifactDirectory = try isContinuation ? continuationArtifactDirectory(for: runID) : artifactDirectory(for: runID)
        let skillArguments = try childSkillArgumentsProvider?(agent, snapshot)
            ?? PiSkillLaunchResolver.childSkillArguments(agent: agent, snapshot: snapshot)
        let missingSkillNames: [String] = []
        let worktreeURL = isContinuation ? nil : (useWorktreeIsolation ? try await createWorktree(for: parentSession, artifactDirectory: artifactDirectory) : nil)
        let resolvedBaseCommit: String? = useWorktreeIsolation
            ? await currentCommit(in: URL(fileURLWithPath: parentSession.worktreePath ?? parentProjectPath))
            : nil
        let childProjectURL = worktreeURL ?? URL(fileURLWithPath: parentSession.worktreePath ?? parentProjectPath)
        let environment = EnvRuntimeEnvironment().environment(
            projectRoot: childProjectURL,
            extra: [
                "AGENT_DECK_NATIVE_SUBAGENT": "1",
                "AGENT_DECK_SUBAGENT_RUN_ID": runID.uuidString,
                "AGENT_DECK_SUBAGENT_AGENT": agent.name,
                "AGENT_DECK_OPENAI_FAST_CONFIG": PiNativeSubagentBridgeExtensions.openAIFastConfigURL().path,
                "MCP_DIRECT_TOOLS": mcpDirectTools(for: agent).isEmpty ? "__none__" : mcpDirectTools(for: agent).joined(separator: ",")
            ]
        )
        let prompt = buildSystemPrompt(agent: agent)
        let promptURL = artifactDirectory.appendingPathComponent("system-prompt.md")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        fileManager.createFile(atPath: artifactDirectory.appendingPathComponent("output.md").path, contents: nil)

        let childSessionDirectory = artifactDirectory.appendingPathComponent("sessions", isDirectory: true)
        var extraArguments: [String] = PiAgentLaunchArgumentBuilder.noExtensionsArgument(settings: AppSettingsStore.shared.settings)
        if !isContinuation {
            extraArguments.append(contentsOf: ["--session-dir", childSessionDirectory.path])
        }
        extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.systemPromptArguments(for: agent, prompt: prompt))
        var bridgeWarnings: [String] = []
        let wantsSupervisorTool = agent.resolved.tools?.contains("contact_supervisor") == true
        if wantsSupervisorTool {
            if let bridgeURL = try? PiNativeSubagentBridgeExtensions.childExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", bridgeURL.path])
            } else {
                bridgeWarnings.append("contact_supervisor was requested, but \(AppBrand.displayName) could not write the child bridge extension.")
            }
        }
        let memoryExtensionURL = AppSettingsStore.shared.settings.agentMemoryEnabled ? try? PiNativeSubagentBridgeExtensions.memoryExtensionURL() : nil
        // Resolved up front (before --tools) so a restrictive agent allowlist can
        // include the `mcp` tool when the bridge is injected; the args themselves are
        // appended below, before the user extensions.
        let mcpArguments = await childMCPArgumentsProvider?(parentSession, agent) ?? []
        extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.toolArguments(.init(
            agent: agent,
            includeSupervisorTool: wantsSupervisorTool && bridgeWarnings.isEmpty,
            includeMemoryTools: memoryExtensionURL != nil,
            includeExaTools: PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment),
            includeFallbackWebFetchTool: !PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment) && WebFetchDependencyService().status().isInstalled,
            includeMCPTool: !mcpArguments.isEmpty
        )))
        // `--no-extensions` is already seeded at the top; the agent's authored
        // extensions append without re-emitting it.
        extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.agentExtensionArguments(for: agent, prependNoExtensions: false))
        if let memoryExtensionURL {
            extraArguments.append(contentsOf: ["--extension", memoryExtensionURL.path])
        }
        if PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment) {
            if let webURL = try? PiNativeSubagentBridgeExtensions.webAccessExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", webURL.path])
            }
        } else if WebFetchDependencyService().status().isInstalled,
                  let webURL = try? PiNativeSubagentBridgeExtensions.fallbackWebFetchExtensionURL() {
            extraArguments.append(contentsOf: ["--extension", webURL.path])
        }
        if let fastURL = try? PiNativeSubagentBridgeExtensions.openAIFastExtensionURL() {
            extraArguments.append(contentsOf: ["--extension", fastURL.path])
        } else {
            bridgeWarnings.append("\(AppBrand.displayName) could not write the OpenAI Fast mode extension.")
        }
        if let auditURL = try? PiNativeSubagentBridgeExtensions.systemPromptAuditExtensionURL() {
            extraArguments.append(contentsOf: ["--extension", auditURL.path])
        } else {
            bridgeWarnings.append("\(AppBrand.displayName) could not write the system prompt audit extension.")
        }
        // Native MCP bridge + scoped catalog (the agent's assigned `mcpServers`), so an
        // agent's MCP assignment works under delegation. Appended here, before the
        // user-selected extensions below, so the `mcp` tool wins any name clash.
        extraArguments.append(contentsOf: mcpArguments)
        // User-selected Pi extensions load LAST so Agent Deck bridges register first and win conflicts.
        extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
            settings: AppSettingsStore.shared.settings,
            projectURL: childProjectURL
        ))
        extraArguments.append("--no-skills")
        extraArguments.append(contentsOf: skillArguments)
        extraArguments.append("--no-prompt-templates")
        extraArguments.append("--no-themes")
        let memoryLaunchContext = try await childMemoryArgumentsProvider?(parentSession, agent, trimmedTask) ?? .empty
        extraArguments.append(contentsOf: memoryLaunchContext.arguments)

        let modelSelection = PiSubagentLaunchPlanner.modelSelection(for: agent, parentSession: parentSession)
        let modelArgument = modelSelection.modelArgument
        let modelDisplayName = modelSelection.displayName
        let tools = displayTools(for: agent, includeSupervisorTool: bridgeWarnings.isEmpty, includeMemoryTools: memoryExtensionURL != nil, includeMCPTool: !mcpArguments.isEmpty)
        let resolvedReadFirstPaths = sanitizedReadFirstPaths(agentReads: agent.resolved.defaultReads ?? [], requestReads: readFirstPaths, projectRoot: URL(fileURLWithPath: parentSession.worktreePath ?? parentProjectPath))
        try childInput(agent: agent, task: trimmedTask, readFirstPaths: resolvedReadFirstPaths).write(
            to: artifactDirectory.appendingPathComponent("input.md"),
            atomically: true,
            encoding: .utf8
        )
        let diagnosticMessages = missingSkillNames.map { "Skill not found: \($0)" } + bridgeWarnings
        var run = continuingRun ?? PiSubagentRunRecord(
            id: runID,
            parentSessionID: parentSession.id,
            mode: .single,
            status: .starting,
            agentName: agent.name,
            task: trimmedTask,
            model: modelDisplayName,
            thinking: agent.resolved.thinking,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: allowOverwrite,
            readFirstPaths: resolvedReadFirstPaths,
            tools: tools,
            skills: agent.resolved.skills,
            concurrencyLimit: nil,
            worktreePolicy: useWorktreeIsolation ? "isolated" : "parent",
            aggregateSummary: nil,
            artifactDirectory: artifactDirectory.path,
            outputPath: artifactDirectory.appendingPathComponent("output.md").path,
            worktreePath: worktreeURL?.path ?? parentSession.worktreePath,
            parentRepoPath: parentSession.worktreePath ?? parentProjectPath,
            baseCommit: resolvedBaseCommit,
            isWorktreeIsolated: useWorktreeIsolation,
            worktreeStatus: useWorktreeIsolation ? .active : PiSubagentWorktreeStatus.none,
            worktreePatchPath: nil,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: diagnosticMessages.isEmpty ? nil : diagnosticMessages.joined(separator: "\n"),
            child: PiSubagentChildRecord(
                id: UUID(),
                runID: runID,
                index: 0,
                agentName: agent.name,
                task: trimmedTask,
                status: .starting,
                model: modelDisplayName,
                thinking: agent.resolved.thinking,
                expectedOutcome: expectedOutcome,
                requestedOutputPath: requestedOutputPath,
                allowOverwrite: allowOverwrite,
                readFirstPaths: resolvedReadFirstPaths,
                currentTool: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                toolCount: nil,
                durationMs: nil,
                artifactDirectory: artifactDirectory.path,
                sessionFile: nil,
                outputPath: artifactDirectory.appendingPathComponent("output.md").path,
                worktreePath: worktreeURL?.path,
                launchCommand: nil,
                executionRunID: nil,
                summary: nil,
                error: nil,
                dependencies: nil,
                injectedMemoryIDs: memoryLaunchContext.memoryIDs,
                injectedMemoryTitles: memoryLaunchContext.memoryTitles,
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            ),
            children: nil,
            graphEdges: nil,
            injectedMemoryIDs: memoryLaunchContext.memoryIDs,
            injectedMemoryTitles: memoryLaunchContext.memoryTitles,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            durationMs: nil
        )
        if isContinuation {
            run.status = .starting
            run.agentName = agent.name
            run.task = trimmedTask
            run.model = modelDisplayName
            run.thinking = agent.resolved.thinking
            run.expectedOutcome = expectedOutcome
            run.requestedOutputPath = requestedOutputPath
            run.allowOverwrite = allowOverwrite
            run.readFirstPaths = resolvedReadFirstPaths
            run.tools = tools
            run.skills = agent.resolved.skills
            run.worktreePolicy = "parent"
            run.outputPath = artifactDirectory.appendingPathComponent("output.md").path
            run.worktreePath = parentSession.worktreePath
            run.parentRepoPath = parentSession.worktreePath ?? parentProjectPath
            run.launchCommand = nil
            run.summary = nil
            run.error = diagnosticMessages.isEmpty ? nil : diagnosticMessages.joined(separator: "\n")
            run.completedAt = nil
            run.durationMs = nil
            run.child = PiSubagentChildRecord(
                id: UUID(),
                runID: runID,
                index: (continuingRun?.child?.index ?? 0) + 1,
                agentName: agent.name,
                task: trimmedTask,
                status: .starting,
                model: modelDisplayName,
                thinking: agent.resolved.thinking,
                expectedOutcome: expectedOutcome,
                requestedOutputPath: requestedOutputPath,
                allowOverwrite: allowOverwrite,
                readFirstPaths: resolvedReadFirstPaths,
                currentTool: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                toolCount: nil,
                durationMs: nil,
                artifactDirectory: artifactDirectory.path,
                sessionFile: continuingRun?.childPiSessionFile,
                outputPath: artifactDirectory.appendingPathComponent("output.md").path,
                worktreePath: nil,
                launchCommand: nil,
                executionRunID: nil,
                summary: nil,
                error: nil,
                dependencies: nil,
                injectedMemoryIDs: memoryLaunchContext.memoryIDs,
                injectedMemoryTitles: memoryLaunchContext.memoryTitles,
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            )
            run.injectedMemoryIDs = memoryLaunchContext.memoryIDs
            run.injectedMemoryTitles = memoryLaunchContext.memoryTitles
        }
        store.upsertSubagentRun(run)
        upsertSubagentStatusCard(run: run, parentSessionID: parentSession.id, isContinuation: isContinuation)

        let childSessionID = UUID()
        let parentSessionID = parentSession.id
        finalTextByRunID[runID] = nil
        // Holds a weak reference to this run's client so its async termination
        // handler can confirm it's still the *current* client for the runID
        // before clearing the slot. A continuation reuses the runID; the previous
        // client's late termination (from `completeIfNeeded`'s `stop()`) must not
        // clobber the newly installed continuation client.
        let terminationHolder = ClientTerminationHolder()
        let client = try PiRPCClient(
            cwd: childProjectURL,
            sessionFile: continuingRun?.childPiSessionFile,
            provider: modelSelection.provider,
            modelArgument: modelArgument,
            extraArguments: extraArguments,
            environment: environment,
            onEvent: { [weak self] events in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for event in events {
                        self.handle(rawLine: event.rawLine, event: event.event, runID: runID, parentSessionID: parentSessionID)
                    }
                }
            },
            onStderr: { [weak self] lines in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for line in lines {
                        self.handle(stderr: line, runID: runID, parentSessionID: parentSessionID)
                    }
                }
            },
            onTermination: { [weak self] exitCode in
                Task { @MainActor [weak self] in self?.handleTermination(exitCode: exitCode, runID: runID, parentSessionID: parentSessionID, terminatingClient: terminationHolder.client) }
            }
        )
        clientsByRunID[runID] = client
        terminationHolder.client = client
        if let onCompletion {
            completionHandlersByRunID[runID] = onCompletion
        }
        run.childSessionID = childSessionID
        run.launchCommand = client.launchCommand
        run.status = .running
        run.child?.status = .running
        run.child?.launchCommand = client.launchCommand
        store.upsertSubagentRun(run)
        client.getState()
        client.prompt(initialTaskPrompt(agent: agent, task: trimmedTask, artifactDirectory: artifactDirectory, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, useWorktreeIsolation: useWorktreeIsolation, readFirstPaths: resolvedReadFirstPaths, isContinuation: isContinuation))
        return run
    }

    func respondToSupervisorRequest(_ requestID: String, parentSessionID: UUID, response: String) {
        guard let request = store.supervisorRequests(for: parentSessionID).first(where: { $0.id == requestID }) else { return }
        supervisorTimeoutTasksByRequestID.removeValue(forKey: requestID)?.cancel()
        store.updateSupervisorRequest(requestID, parentSessionID: parentSessionID) { request in
            request.status = .answered
            request.response = response
        }
        store.updateSubagentRun(request.runID, parentSessionID: parentSessionID) { run in
            let now = Date()
            if run.status == .blocked { run.status = .running }
            if run.child?.status == .blocked { run.child?.status = .running }
            run.updatedAt = now
            run.child?.updatedAt = now
        }
        clientsByRunID[request.runID]?.respondToExtensionUI(id: request.bridgeRequestID ?? requestID, value: response)
    }

    func cancelSupervisorRequest(_ requestID: String, parentSessionID: UUID) {
        guard let request = store.supervisorRequests(for: parentSessionID).first(where: { $0.id == requestID }) else { return }
        supervisorTimeoutTasksByRequestID.removeValue(forKey: requestID)?.cancel()
        store.updateSupervisorRequest(requestID, parentSessionID: parentSessionID) { request in
            request.status = .cancelled
            request.response = "Cancelled by supervisor."
        }
        store.updateSubagentRun(request.runID, parentSessionID: parentSessionID) { run in
            let now = Date()
            if run.status == .blocked { run.status = .running }
            if run.child?.status == .blocked { run.child?.status = .running }
            run.updatedAt = now
            run.child?.updatedAt = now
        }
        clientsByRunID[request.runID]?.cancelExtensionUI(id: request.bridgeRequestID ?? requestID)
    }

    func stop(runID: UUID, parentSessionID: UUID, recordTranscript: Bool = true) {
        guard let client = clientsByRunID.removeValue(forKey: runID) else { return }
        cancelSupervisorTimeouts(for: runID, parentSessionID: parentSessionID)
        clearStreamingState(for: runID)
        client.stop()
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            let completedAt = Date()
            run.status = .stopped
            run.child?.status = .stopped
            run.updatedAt = completedAt
            run.completedAt = completedAt
            run.durationMs = durationMilliseconds(from: run.createdAt, to: completedAt)
            if var child = run.child {
                child.updatedAt = completedAt
                child.durationMs = durationMilliseconds(from: child.createdAt, to: completedAt)
                run.child = child
            }
        }
        notifyCompletion(runID: runID, parentSessionID: parentSessionID)
        if recordTranscript {
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Stopped", text: "Deck agent run stopped."))
        }
    }

    func stopAll(recordTranscript: Bool = true) {
        for (parentSessionID, runs) in store.subagentRunsBySessionID {
            for run in runs where clientsByRunID[run.id] != nil {
                stop(runID: run.id, parentSessionID: parentSessionID, recordTranscript: recordTranscript)
            }
        }

        for runID in Array(clientsByRunID.keys) {
            clientsByRunID.removeValue(forKey: runID)?.stop()
            clearStreamingState(for: runID)
        }

        for task in supervisorTimeoutTasksByRequestID.values {
            task.cancel()
        }
        supervisorTimeoutTasksByRequestID.removeAll()
        completionHandlersByRunID.removeAll()
    }

    private func handle(rawLine: String, event: PiAgentRPCEvent?, runID: UUID, parentSessionID: UUID) {
#if DEBUG
        if ProcessInfo.processInfo.environment["AGENTDECK_RPC_LOG"] != nil {
            NSLog("PiSubagentRunService.handle rawLine=%@ event=%@", rawLine, event == nil ? "nil" : "nonnil")
        }
#endif
        guard let event else {
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .raw, title: "Raw Output", text: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        switch event.type {
        case "response":
            if event.command == "get_state", let data = event.data {
                store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                    run.childPiSessionFile = data["sessionFile"]?.stringValue ?? run.childPiSessionFile
                    if let resolvedModel = resolvedModelName(from: data) {
                        run.model = resolvedModel
                        run.child?.model = resolvedModel
                    }
                    if let thinkingLevel = resolvedThinkingLevel(from: data) {
                        run.thinking = thinkingLevel
                        run.child?.thinking = thinkingLevel
                    }
                    run.child?.sessionFile = run.childPiSessionFile
                }
            } else if event.command == "get_session_stats", let data = event.data {
                applySubagentStats(data, runID: runID, parentSessionID: parentSessionID)
                // Stats arrived — cancel the timeout and complete now.
                if pendingStatsTasksByRunID[runID] != nil {
                    pendingStatsTasksByRunID.removeValue(forKey: runID)?.cancel()
                    completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
                }
            }
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            let toolName = event.toolName ?? "tool"
            let toolText = event.args?.compactDescription ?? event.partialResult?.compactDescription ?? event.result?.compactDescription ?? event.error?.compactDescription ?? event.type ?? "tool"
            let transcript = PiAgentTranscriptEntry(sessionID: parentSessionID, role: .tool, title: "Tool: \(toolName)", text: toolText, rawJSON: rawLine)
            if let toolCallID = event.toolCallId {
                let key = "\(runID.uuidString):\(toolCallID)"
                let entryID = toolEntryIDsByCallID[key] ?? UUID()
                toolEntryIDsByCallID[key] = event.type == "tool_execution_end" ? nil : entryID
                store.upsertSubagentTranscript(.init(id: entryID, sessionID: transcript.sessionID, role: transcript.role, title: transcript.title, text: transcript.text, rawJSON: transcript.rawJSON), runID: runID, parentSessionID: parentSessionID)
            } else {
                store.appendSubagentTranscript(transcript, runID: runID, parentSessionID: parentSessionID)
            }
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.child?.currentTool = event.type == "tool_execution_end" ? nil : toolName
                run.child?.updatedAt = Date()
            }
        case "message_update":
            handleMessageUpdate(event, runID: runID, parentSessionID: parentSessionID)
        case "message_end":
            handleMessageEnd(event, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
        case "extension_ui_request":
            handleExtensionUIRequest(event, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
        case "agent_end":
            requestStatsThenComplete(runID: runID, parentSessionID: parentSessionID)
        case "turn_end":
            break
        default:
            if let type = event.type, type != "message_update" {
                store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .raw, title: type, text: event.data?.compactDescription ?? rawLine, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            }
        }
    }

    private func handleMessageUpdate(_ event: PiAgentRPCEvent, runID: UUID, parentSessionID: UUID) {
        guard let assistantEvent = event.assistantMessageEvent else { return }
        let deltaType = assistantEvent["type"]?.stringValue ?? "update"
        guard deltaType == "text_delta" || deltaType == "thinking_delta" else { return }
        let delta = assistantEvent["delta"]?.stringValue ?? ""
        guard !delta.isEmpty else { return }
        if deltaType == "thinking_delta" {
            let entryID = thinkingEntryIDsByRunID[runID] ?? UUID()
            thinkingEntryIDsByRunID[runID] = entryID
            thinkingTextByRunID[runID, default: ""] += delta
        } else {
            let entryID = assistantEntryIDsByRunID[runID] ?? UUID()
            assistantEntryIDsByRunID[runID] = entryID
            assistantTextByRunID[runID, default: ""] += delta
        }
        scheduleStreamingFlush(runID: runID, parentSessionID: parentSessionID)
    }

    private func scheduleStreamingFlush(runID: UUID, parentSessionID: UUID) {
        guard streamFlushTasksByRunID[runID] == nil else { return }
        streamFlushTasksByRunID[runID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.streamFlushTasksByRunID[runID] = nil
                self?.flushStreamingEntries(runID: runID, parentSessionID: parentSessionID)
            }
        }
    }

    private func flushStreamingEntries(runID: UUID, parentSessionID: UUID) {
        if let thinkingEntryID = thinkingEntryIDsByRunID[runID],
           let thinkingText = thinkingTextByRunID[runID],
           !thinkingText.isEmpty {
            store.upsertSubagentTranscript(.init(
                id: thinkingEntryID,
                sessionID: parentSessionID,
                role: .thinking,
                title: "Thinking",
                text: thinkingText,
                rawJSON: nil
            ), runID: runID, parentSessionID: parentSessionID, before: assistantEntryIDsByRunID[runID])
        }

        if let assistantEntryID = assistantEntryIDsByRunID[runID],
           let assistantText = assistantTextByRunID[runID] {
            store.upsertSubagentTranscript(.init(
                id: assistantEntryID,
                sessionID: parentSessionID,
                role: .assistant,
                title: "Assistant",
                text: assistantText,
                rawJSON: nil
            ), runID: runID, parentSessionID: parentSessionID)
        }
    }

    private func clearStreamingState(for runID: UUID) {
        streamFlushTasksByRunID.removeValue(forKey: runID)?.cancel()
        pendingStatsTasksByRunID.removeValue(forKey: runID)?.cancel()
        assistantEntryIDsByRunID[runID] = nil
        assistantTextByRunID[runID] = nil
        thinkingEntryIDsByRunID[runID] = nil
        thinkingTextByRunID[runID] = nil
        let keyPrefix = "\(runID.uuidString):"
        toolEntryIDsByCallID = toolEntryIDsByCallID.filter { !$0.key.hasPrefix(keyPrefix) }
    }

    private func resolvedModelName(from data: JSONValue) -> String? {
        guard let model = data["model"] else { return nil }
        if let modelID = model.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty {
            return modelID
        }
        let provider = model["provider"]?.stringValue ?? model["providerId"]?.stringValue
        let modelID = model["id"]?.stringValue ?? model["modelId"]?.stringValue ?? model["model"]?.stringValue
        guard let trimmedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty else { return nil }
        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            return "\(provider)/\(trimmedModel)"
        }
        return trimmedModel
    }

    private func resolvedThinkingLevel(from data: JSONValue) -> String? {
        let level = data["thinkingLevel"]?.stringValue ?? data["level"]?.stringValue
        guard let trimmed = level?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func handle(stderr line: String, runID: UUID, parentSessionID: UUID) {
        guard !line.localizedCaseInsensitiveContains("ready for input") else { return }
        store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .stderr, title: "stderr", text: line), runID: runID, parentSessionID: parentSessionID)
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.error = [run.error, line].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func handleTermination(exitCode: Int32, runID: UUID, parentSessionID: UUID, terminatingClient: PiRPCClient?) {
        // Only act if the terminating client is still the *current* client for
        // this runID. A continuation reuses the runID and installs a new client;
        // the previous client's late async termination (e.g. from
        // `completeIfNeeded`'s `stop()`) — once that client is released the weak
        // identity is nil — must not clobber the new client or fail the active
        // run. So both "no identity" and "different identity" are treated as stale.
        guard let terminatingClient, clientsByRunID[runID] === terminatingClient else { return }
        clientsByRunID[runID] = nil
        cancelSupervisorTimeouts(for: runID, parentSessionID: parentSessionID)
        clearStreamingState(for: runID)
        if exitCode == 0 {
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
        } else {
            var didFailActiveRun = false
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                guard run.status.isActive else { return }
                didFailActiveRun = true
                let completedAt = Date()
                run.status = .failed
                run.child?.status = .failed
                run.error = "Child Pi process exited with code \(exitCode)."
                run.child?.error = run.error
                run.updatedAt = completedAt
                run.completedAt = completedAt
                run.durationMs = durationMilliseconds(from: run.createdAt, to: completedAt)
                if var child = run.child {
                    child.updatedAt = completedAt
                    child.durationMs = durationMilliseconds(from: child.createdAt, to: completedAt)
                    run.child = child
                }
            }
            guard didFailActiveRun else { return }
            notifyCompletion(runID: runID, parentSessionID: parentSessionID)
            updateSubagentStatusCard(runID: runID, parentSessionID: parentSessionID, statusText: "Child Pi process exited with code \(exitCode).")
        }
    }

    private func handleMessageEnd(_ event: PiAgentRPCEvent, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let message = event.message else { return }
        let role = message["role"]?.stringValue ?? "assistant"
        let text = role == "assistant" ? extractAssistantText(from: message) : extractText(from: message)
        if role == "assistant" {
            streamFlushTasksByRunID[runID]?.cancel()
            streamFlushTasksByRunID[runID] = nil
            let assistantEntryID = assistantEntryIDsByRunID[runID] ?? UUID()
            let thinkingEntryID = thinkingEntryIDsByRunID[runID] ?? UUID()
            let thinkingBeforeID = assistantEntryIDsByRunID[runID]
            assistantEntryIDsByRunID[runID] = nil
            assistantTextByRunID[runID] = nil
            thinkingEntryIDsByRunID[runID] = nil
            thinkingTextByRunID[runID] = nil

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.upsertSubagentTranscript(.init(id: assistantEntryID, sessionID: parentSessionID, role: .assistant, title: "Assistant", text: text, rawJSON: nil), runID: runID, parentSessionID: parentSessionID)
            } else {
                let thinkingText = extractAssistantThinking(from: message)
                if !thinkingText.isEmpty {
                    store.upsertSubagentTranscript(.init(id: thinkingEntryID, sessionID: parentSessionID, role: .thinking, title: "Thinking", text: thinkingText, rawJSON: nil), runID: runID, parentSessionID: parentSessionID, before: thinkingBeforeID)
                }
            }
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let transcriptRole = PiAgentTranscriptRole(rawValue: role) ?? .raw
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: transcriptRole, title: role.capitalized, text: text, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        }
        guard role == "assistant" else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalTextByRunID[runID] = text
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.summary = text
                run.child?.summary = text
                if let usage = message["usage"] {
                    run.child?.inputTokens = usage["input"]?.numberValue.map(Int.init)
                    run.child?.outputTokens = usage["output"]?.numberValue.map(Int.init)
                    run.child?.totalTokens = usage["totalTokens"]?.numberValue.map(Int.init) ?? usage["total"]?.numberValue.map(Int.init)
                }
            }
            if let outputURL = outputURL(for: runID, parentSessionID: parentSessionID) {
                try? text.write(to: outputURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// On `agent_end`, ask the child's still-live Pi session for its stats (the
    /// only source of its cost) and defer completion until the response lands or
    /// a short timeout fires. Completion otherwise still happens via process
    /// termination, so this never adds latency in the common one-shot case.
    private func requestStatsThenComplete(runID: UUID, parentSessionID: UUID) {
        // Already awaiting stats (e.g. a duplicate agent_end) — keep waiting; the
        // in-flight request/timeout will complete the run.
        guard pendingStatsTasksByRunID[runID] == nil else { return }
        guard let client = clientsByRunID[runID] else {
            // No live client (already torn down) — just finish.
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
            return
        }
        client.getSessionStats()
        pendingStatsTasksByRunID[runID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.pendingStatsTasksByRunID.removeValue(forKey: runID) != nil else { return }
                self.completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
            }
        }
    }

    /// Parses a child `get_session_stats` response onto `run.child`, mirroring the
    /// parent path (`PiAgentRunnerService.handle`). Only overwrites fields that are
    /// present so the `usage`-block token capture stays as a fallback.
    private func applySubagentStats(_ data: JSONValue, runID: UUID, parentSessionID: UUID) {
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard var child = run.child else { return }
            if let v = data["tokens"]?["input"]?.numberValue { child.inputTokens = Int(v) }
            if let v = data["tokens"]?["output"]?.numberValue { child.outputTokens = Int(v) }
            if let v = data["tokens"]?["cacheRead"]?.numberValue { child.cacheReadTokens = Int(v) }
            if let v = data["tokens"]?["cacheWrite"]?.numberValue { child.cacheWriteTokens = Int(v) }
            if let v = data["tokens"]?["total"]?.numberValue { child.totalTokens = Int(v) }
            if let v = data["cost"]?.numberValue { child.cost = v }
            if let v = data["contextUsage"]?["tokens"]?.numberValue { child.contextTokens = Int(v) }
            run.child = child
        }
    }

    private func completeIfNeeded(runID: UUID, parentSessionID: UUID) {
        var shouldAppend = false
        var finalSummary = finalTextByRunID[runID] ?? "Completed without a text summary."
        var outputPath: String?
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard run.status.isActive else { return }
            let completedAt = Date()
            run.status = .completed
            run.child?.status = .completed
            run.updatedAt = completedAt
            run.completedAt = completedAt
            run.durationMs = durationMilliseconds(from: run.createdAt, to: completedAt)
            run.summary = finalSummary
            if var child = run.child {
                child.status = .completed
                child.summary = finalSummary
                child.updatedAt = completedAt
                child.completedAt = completedAt
                child.durationMs = durationMilliseconds(from: child.createdAt, to: completedAt)
                run.child = child
            }
            outputPath = run.outputPath
            shouldAppend = true
        }
        notifyCompletion(runID: runID, parentSessionID: parentSessionID)
        cancelSupervisorTimeouts(for: runID, parentSessionID: parentSessionID)
        clientsByRunID[runID]?.stop()
        clientsByRunID[runID] = nil
        clearStreamingState(for: runID)
        if shouldAppend {
            if finalSummary.count > 1200 {
                finalSummary = String(finalSummary.prefix(1200)) + "…"
            }
            let artifactLine = outputPath.map { "\n\nArtifact: \($0)" } ?? ""
            updateSubagentStatusCard(runID: runID, parentSessionID: parentSessionID, statusText: "\(finalSummary)\(artifactLine)")
        }
    }

    private func notifyCompletion(runID: UUID, parentSessionID: UUID) {
        guard let handler = completionHandlersByRunID.removeValue(forKey: runID),
              let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        handler(run)
    }

    private func scheduleSupervisorTimeout(requestID: String, runID: UUID, parentSessionID: UUID) {
        supervisorTimeoutTasksByRequestID.removeValue(forKey: requestID)?.cancel()
        supervisorTimeoutTasksByRequestID[requestID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            await MainActor.run {
                self?.timeoutSupervisorRequest(requestID, runID: runID, parentSessionID: parentSessionID)
            }
        }
    }

    private func timeoutSupervisorRequest(_ requestID: String, runID: UUID, parentSessionID: UUID) {
        guard let request = store.supervisorRequests(for: parentSessionID).first(where: { $0.id == requestID && $0.status == .pending }) else { return }
        supervisorTimeoutTasksByRequestID.removeValue(forKey: requestID)?.cancel()
        clientsByRunID[runID]?.cancelExtensionUI(id: request.bridgeRequestID ?? requestID)
        store.updateSupervisorRequest(requestID, parentSessionID: parentSessionID) { request in
            request.status = .cancelled
            request.response = "Timed out waiting for supervisor response."
        }
        failRun(runID: runID, parentSessionID: parentSessionID, message: "Timed out waiting for supervisor response to: \(request.title)")
    }

    private func cancelSupervisorTimeouts(for runID: UUID, parentSessionID: UUID) {
        for request in store.supervisorRequests(for: parentSessionID) where request.runID == runID {
            supervisorTimeoutTasksByRequestID.removeValue(forKey: request.id)?.cancel()
        }
    }

    private func failRun(runID: UUID, parentSessionID: UUID, message: String) {
        let client = clientsByRunID.removeValue(forKey: runID)
        client?.stop()
        cancelSupervisorTimeouts(for: runID, parentSessionID: parentSessionID)
        clearStreamingState(for: runID)
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard run.status.isActive else { return }
            let completedAt = Date()
            run.status = .failed
            run.child?.status = .failed
            run.error = message
            run.child?.error = message
            run.updatedAt = completedAt
            run.completedAt = completedAt
            run.durationMs = durationMilliseconds(from: run.createdAt, to: completedAt)
            if var child = run.child {
                child.updatedAt = completedAt
                child.durationMs = durationMilliseconds(from: child.createdAt, to: completedAt)
                run.child = child
            }
        }
        notifyCompletion(runID: runID, parentSessionID: parentSessionID)
        updateSubagentStatusCard(runID: runID, parentSessionID: parentSessionID, statusText: message)
    }

    private func createWorktree(for parentSession: PiAgentSessionRecord, artifactDirectory: URL) async throws -> URL {
        let worktreeURL = artifactDirectory.appendingPathComponent("worktree", isDirectory: true)
        guard let parentProjectPath = parentSession.projectPathForProjectFeatures else { throw NativeSubagentError.noProjectUnavailable }
        let projectPath = parentSession.worktreePath ?? parentProjectPath
        let result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            result = try await Self.runGitDetached(arguments: ["-C", projectPath, "worktree", "add", "--detach", worktreeURL.path, "HEAD"], timeout: 30)
        } catch {
            throw NativeSubagentError.worktreeFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeSubagentError.worktreeFailed(message.isEmpty ? "git worktree add failed" : message)
        }
        return worktreeURL
    }

    private func currentCommit(in repositoryURL: URL) async -> String? {
        guard let result = try? await Self.runGitDetached(arguments: ["-C", repositoryURL.path, "rev-parse", "HEAD"], timeout: 5),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Async wrapper that runs the existing nonisolated `runGit` on the
    /// default executor, so callers on `@MainActor` don't block the UI for
    /// up to `timeout` seconds while git spawns and waits.
    private nonisolated static func runGitDetached(arguments: [String], timeout: TimeInterval) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try await Task.detached(priority: .userInitiated) {
            try Self.runGit(arguments: arguments, timeout: timeout)
        }.value
    }

    private nonisolated static func runGit(arguments: [String], timeout: TimeInterval) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        try process.run()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }
            throw NSError(
                domain: "AgentDeckGitHelper",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) timed out after \(Int(timeout))s."]
            )
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    private func artifactDirectory(for runID: UUID) throws -> URL {
        let appSupport = URL.applicationSupportDirectory
        let directory = appSupport
            .appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
            .appendingPathComponent("Subagent Runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func continuationArtifactDirectory(for runID: UUID) throws -> URL {
        let directory = try artifactDirectory(for: runID)
            .appendingPathComponent("turns", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func continuableRun(parentSessionID: UUID, runID: UUID?) throws -> PiSubagentRunRecord? {
        guard let runID else { return nil }
        guard let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else {
            throw NativeSubagentError.continuationUnavailable("No Deck agent with ID `\(runID.uuidString)` exists in this parent session.")
        }
        guard run.mode == .single else {
            throw NativeSubagentError.continuationUnavailable("Only single Deck agent runs can be continued.")
        }
        guard !run.status.isActive else {
            throw NativeSubagentError.continuationUnavailable("Deck agent `\(runID.uuidString)` is still active; wait for it to finish or stop it before continuing.")
        }
        guard run.isWorktreeIsolated != true else {
            throw NativeSubagentError.continuationUnavailable("Worktree-isolated Deck agents cannot be continued safely. Start a fresh Deck agent instead.")
        }
        guard let sessionFile = run.childPiSessionFile?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionFile.isEmpty else {
            throw NativeSubagentError.continuationUnavailable("Deck agent `\(runID.uuidString)` has no child session file to resume. Start a fresh Deck agent instead.")
        }
        guard fileManager.fileExists(atPath: sessionFile) else {
            throw NativeSubagentError.continuationUnavailable("The child session file for `\(runID.uuidString)` no longer exists. Start a fresh Deck agent instead.")
        }
        return run
    }

    private func outputURL(for runID: UUID, parentSessionID: UUID) -> URL? {
        guard let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), let outputPath = run.outputPath else { return nil }
        return URL(fileURLWithPath: outputPath)
    }

    private func upsertSubagentStatusCard(run: PiSubagentRunRecord, parentSessionID: UUID, isContinuation: Bool) {
        let turnText = (run.child?.index ?? 0) > 0 ? "\n\nContinuation: \((run.child?.index ?? 0) + 1)" : ""
        let text = "Deck agent ID: \(run.id.uuidString)\n\n\(run.agentName) is running.\n\nTask: \(run.task)\(turnText)"
        let entry = PiAgentTranscriptEntry(
            sessionID: parentSessionID,
            role: .status,
            title: "Deck Agent",
            text: text,
            rawJSON: subagentStartedAuditPayload(run: run)
        )
        if isContinuation, let existingID = subagentStatusEntryID(runID: run.id, parentSessionID: parentSessionID) {
            store.updateEntry(existingID, in: parentSessionID) { existing in
                existing.title = entry.title
                existing.text = entry.text
                existing.rawJSON = entry.rawJSON
                existing.timestamp = Date()
            }
        } else {
            store.append(entry)
        }
    }

    private func updateSubagentStatusCard(runID: UUID, parentSessionID: UUID, statusText: String) {
        guard let entryID = subagentStatusEntryID(runID: runID, parentSessionID: parentSessionID),
              let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        let summary = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuationLine = (run.child?.index ?? 0) > 0 ? "\n\nContinuation: \((run.child?.index ?? 0) + 1)" : ""
        let taskLine = "\n\nLatest task: \(run.task)"
        store.updateEntry(entryID, in: parentSessionID) { entry in
            entry.title = "Deck Agent"
            entry.text = "Deck agent ID: \(run.id.uuidString)\n\n\(run.agentName) \(run.status.rawValue).\(continuationLine)\(taskLine)\n\n\(summary)"
            entry.rawJSON = subagentStartedAuditPayload(run: run)
            entry.timestamp = Date()
        }
    }

    private func subagentStatusEntryID(runID: UUID, parentSessionID: UUID) -> UUID? {
        store.transcript(for: parentSessionID).first { entry in
            guard let rawJSON = entry.rawJSON,
                  let data = rawJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  (type == "agent_deck_subagent_started" || type == "agent_deck_subagent_card"),
                  let rawRunID = object["runID"] as? String else { return false }
            return UUID(uuidString: rawRunID) == runID
        }?.id
    }

    private func subagentStartedAuditPayload(run: PiSubagentRunRecord) -> String? {
        let latestArtifactDirectory = run.child?.artifactDirectory ?? run.artifactDirectory
        let payload: [String: Any] = [
            "type": "agent_deck_subagent_card",
            "runID": run.id.uuidString,
            "agent": run.agentName,
            "artifactDirectory": latestArtifactDirectory,
            "turnIndex": run.child?.index ?? 0,
            "authoredSystemPromptPath": URL(fileURLWithPath: latestArtifactDirectory).appendingPathComponent("system-prompt.md").path,
            "finalSystemPromptPath": URL(fileURLWithPath: latestArtifactDirectory).appendingPathComponent("final-system-prompt.md").path
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func durationMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func displayTools(for agent: EffectiveAgentRecord, includeSupervisorTool: Bool, includeMemoryTools: Bool, includeMCPTool: Bool) -> [String] {
        PiAgentLaunchArgumentBuilder.resolvedTools(.init(
            agent: agent,
            includeSupervisorTool: includeSupervisorTool,
            includeMemoryTools: includeMemoryTools,
            includeExaTools: true,
            includeFallbackWebFetchTool: true,
            includeMCPTool: includeMCPTool
        ))
    }

    private func buildSystemPrompt(agent: EffectiveAgentRecord) -> String {
        var sections: [String] = []
        if !agent.resolved.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(agent.resolved.systemPrompt)
        }
        sections.append(nativeBoundaryPrompt(agent: agent))
        return sections.joined(separator: "\n\n")
    }

    private func nativeBoundaryPrompt(agent: EffectiveAgentRecord) -> String {
        var lines = [
            "This is a delegated child session. Complete only the assigned task; the parent/user remain decision authority.",
            "",
            "Boundaries:",
            "- Do not launch other agents.",
            "- Do not continue old parent requests unless the current task explicitly asks for a continuation."
        ]

        if agent.resolved.tools?.contains("contact_supervisor") == true {
            lines.append(contentsOf: [
                "- If blocked on a product, architecture, scope, approval, or ambiguity decision, call `contact_supervisor` with `kind: \"need_decision\"` and one focused question.",
                "- Use `contact_supervisor` with `kind: \"interview_request\"` only when a structured set of questions is needed.",
                "- Use `contact_supervisor` with `kind: \"progress_update\"` sparingly for meaningful non-blocking updates.",
                "- Return final results normally; do not use `contact_supervisor` for routine completion."
            ])
        } else {
            lines.append(contentsOf: [
                "- If blocked on a product, architecture, scope, approval, or ambiguity decision, report the decision needed in your final response.",
                "- Return final results normally."
            ])
        }

        lines.append("- Prefer narrow, correct changes over broad rewrites.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func initialTaskPrompt(agent: EffectiveAgentRecord, task: String, artifactDirectory: URL, expectedOutcome: PiSubagentExpectedOutcome, requestedOutputPath: String?, allowOverwrite: Bool, useWorktreeIsolation: Bool, readFirstPaths: [String], isContinuation: Bool) -> String {
        var lines: [String] = []
        if isContinuation {
            lines.append("Delegated continuation: this resumes your existing child session. Prior child messages are available as context, but the task below is the only active assignment. The expected outcome below supersedes any previous expected outcome from earlier assignments in this child session.")
        } else {
            lines.append("Delegated assignment: the task below is the only active assignment for this fresh child session. Do not call `managed_subagent` or continue a previous parent tool request.")
        }
        if !readFirstPaths.isEmpty {
            lines.append("Read current project files first if relevant; treat as hints, not injected truth: \(readFirstPaths.joined(separator: ", "))")
        }
        if let output = agent.resolved.output, !output.isEmpty {
            lines.append("Agent configured output is `\(output)`. Treat this as advisory only unless the expected outcome below explicitly names that project file.")
        }
        lines.append("Artifact directory: \(artifactDirectory.path)")
        lines.append("Expected outcome: \(expectedOutcome.displayName)")
        switch expectedOutcome {
        case .reportOnly:
            lines.append("Write the final answer normally. Do not create, edit, delete, or overwrite project files.")
        case .editFilesInWorktree:
            lines.append("Edit project files only in the current isolated worktree. Do not attempt to apply changes back to the parent checkout; \(AppBrand.displayName) will review/apply/discard the worktree diff.")
        case .writeProjectFile:
            if let requestedOutputPath, !requestedOutputPath.isEmpty {
                lines.append("Write/update exactly this project-relative output file: \(requestedOutputPath).")
            }
            lines.append(allowOverwrite ? "Overwrite policy: overwriting that exact file is allowed if needed." : "Overwrite policy: do not overwrite an existing file; if it exists, report that instead of modifying it.")
            if useWorktreeIsolation {
                lines.append("Write this file in the isolated worktree only; \(AppBrand.displayName) will review/apply/discard the patch.")
            }
        case .directProjectWrites:
            lines.append("Direct project writes were explicitly allowed by the user for this run. Keep edits limited to the task scope and mention every changed path in the final response.")
        }
        lines.append("Task:\n\(task)")
        return lines.joined(separator: "\n\n")
    }

    private func childInput(agent: EffectiveAgentRecord, task: String, readFirstPaths: [String]) -> String {
        var sections = [
            """
        # Deck agent input

        Agent: \(agent.name)
        Description: \(agent.resolved.description)
        Skills: \(PiSkillLaunchResolver.normalizedNames(agent.resolved.skills).joined(separator: ", "))

        ## Task

        \(task)
        """
        ]
        if !readFirstPaths.isEmpty {
            sections.append("""
            ## Read first

            \(readFirstPaths.joined(separator: "\n"))
            """)
        }
        return sections.joined(separator: "\n\n")
    }

    private func sanitizedReadFirstPaths(agentReads: [String], requestReads: [String], projectRoot: URL) -> [String] {
        let allReads = agentReads + requestReads
        let rootPath = projectRoot.standardizedFileURL.path
        return distinctPreservingOrder(allReads).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else { return nil }
            let candidate = projectRoot.appendingPathComponent(trimmed).standardizedFileURL
            guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
            return trimmed
        }
    }

    private func distinctPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private func mcpDirectTools(for agent: EffectiveAgentRecord) -> [String] {
        agent.resolved.mcpDirectTools ?? []
    }

    private func resolveSkillBlocks(named names: [String], snapshot: ScanSnapshot) -> [ResolvedSkillBlock] {
        var recordsByName: [String: SkillRecord] = [:]
        for skill in snapshot.librarySkills + snapshot.skills {
            recordsByName[skill.name] = skill
        }
        return names.compactMap { name in
            guard let record = recordsByName[name] else { return nil }
            let content = skillMarkdown(for: record)
            return ResolvedSkillBlock(name: name, source: skillSourceDescription(for: record), path: record.filePath, content: content)
        }
    }

    private func skillMarkdown(for record: SkillRecord) -> String {
        if let raw = try? String(contentsOfFile: record.filePath, encoding: .utf8), !raw.isEmpty { return raw }
        return record.body
    }

    private func skillSourceDescription(for record: SkillRecord) -> String {
        switch record.source.kind {
        case .project: return "catalog"
        case .legacyProject: return "catalog"
        case .global: return "global"
        case .library: return "library"
        case .package: return "package"
        case .builtin: return "builtin"
        case .override: return "override"
        }
    }

    private func handleExtensionUIRequest(_ event: PiAgentRPCEvent, rawLine: String, runID: UUID, parentSessionID: UUID) {
#if DEBUG
        if ProcessInfo.processInfo.environment["AGENTDECK_RPC_LOG"] != nil {
            NSLog("handleExtensionUIRequest title=%@ id=%@", event.title ?? "nil", event.id ?? "nil")
        }
#endif
        let title = event.title ?? event.method ?? "extension UI"
        if title == "AGENT_DECK_BRIDGE system_prompt_audit", let requestID = event.id {
            handleSystemPromptAuditBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
            return
        }
        if title == "AGENT_DECK_BRIDGE memory_write", let requestID = event.id {
            handleMemoryWriteBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
            return
        }
        if title == "AGENT_DECK_BRIDGE memory_mark_stale", let requestID = event.id {
            handleMemoryMarkStaleBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
            return
        }
        if title == "AGENT_DECK_BRIDGE memory_search", let requestID = event.id {
            handleMemorySearchBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
            return
        }
        if title == "AGENT_DECK_BRIDGE mcp", let requestID = event.id {
            handleMCPBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
            return
        }
        guard title == "AGENT_DECK_BRIDGE contact_supervisor", let requestID = event.id else {
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: title, text: event.message?.compactDescription ?? "Extension UI request", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse supervisor request.")
            return
        }
        let requestKindRaw = json["requestKind"] as? String ?? "progress_update"
        let kind = PiSubagentSupervisorRequestKind(rawValue: requestKindRaw) ?? .progressUpdate
        let message = json["message"] as? String ?? ""
        let requestTitle = json["title"] as? String ?? supervisorTitle(for: kind)
        let childID = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.child?.id
        let appRequestID = [runID.uuidString, childID?.uuidString, requestID].compactMap { $0 }.joined(separator: ":")
        let request = PiSubagentSupervisorRequest(
            id: appRequestID,
            bridgeRequestID: requestID,
            runID: runID,
            parentSessionID: parentSessionID,
            childID: childID,
            kind: kind,
            title: requestTitle,
            message: message,
            status: kind.isBlocking ? .pending : .answered,
            response: kind.isBlocking ? nil : "Acknowledged.",
            createdAt: Date(),
            updatedAt: Date()
        )
        store.upsertSupervisorRequest(request)
        store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: "Supervisor · \(kind.rawValue)", text: message, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        if kind.isBlocking {
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.status = .blocked
                run.child?.status = .blocked
                run.updatedAt = Date()
                run.child?.updatedAt = Date()
            }
            scheduleSupervisorTimeout(requestID: appRequestID, runID: runID, parentSessionID: parentSessionID)
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Needs Decision", text: "Request ID: \(appRequestID)\n\n\(message)"))
        } else {
            store.append(.init(sessionID: parentSessionID, role: .status, title: requestTitle, text: message))
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "Acknowledged.")
        }
    }

    private func handleMCPBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiMCPBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the mcp request.")
            return
        }
        let agentName = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.agentName
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMCPBridgeRequest?(parentSessionID, runID, agentName, request) ?? "\(AppBrand.displayName)'s MCP bridge is not available."
            self.clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMemoryMarkStaleBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryStaleBridgeRequest.self, from: data) else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the stale memory request.")
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse stale memory request.", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        let agentName = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.agentName
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemoryMarkStale?(parentSessionID, runID, agentName, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMemorySearchBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemorySearchBridgeRequest.self, from: data) else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the memory search request.")
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse memory search request.", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        let agentName = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.agentName
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemorySearch?(parentSessionID, runID, agentName, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMemoryWriteBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryWriteBridgeRequest.self, from: data) else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the memory write request.")
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse memory write request.", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        let agentName = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.agentName
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemoryWrite?(parentSessionID, runID, agentName, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func bridgePayload(from event: PiAgentRPCEvent) -> String? {
        if let prefill = event.prefill, !prefill.isEmpty { return prefill }
        if let message = event.message?.stringValue, !message.isEmpty { return message }
        return event.message?.compactDescription
    }

    private func handleSystemPromptAuditBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSystemPromptAuditBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the system prompt audit request.")
            return
        }

        if let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) {
            let artifactDirectory = URL(fileURLWithPath: run.child?.artifactDirectory ?? run.artifactDirectory)
            let outputURL = artifactDirectory.appendingPathComponent("final-system-prompt.md")
            try? request.systemPrompt.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: "System Prompt Captured", text: "Captured \(request.systemPrompt.count) characters from Pi runtime.", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "System prompt captured.")
    }

    private func supervisorTitle(for kind: PiSubagentSupervisorRequestKind) -> String {
        switch kind {
        case .progressUpdate: return "Deck Agent Progress"
        case .needDecision: return "Deck Agent Needs Decision"
        case .interviewRequest: return "Deck Agent Interview Request"
        }
    }

    private func extractText(from message: JSONValue) -> String {
        if let content = message["content"] {
            switch content {
            case let .string(value): return value
            case let .array(blocks):
                return blocks.compactMap { block in
                    block["text"]?.stringValue ?? block["thinking"]?.stringValue ?? block["name"]?.stringValue
                }.joined(separator: "\n")
            default:
                return content.compactDescription
            }
        }
        if let output = message["output"]?.stringValue { return output }
        if let command = message["command"]?.stringValue { return command }
        return ""
    }

    private func extractAssistantText(from message: JSONValue) -> String {
        if let content = message["content"] {
            switch content {
            case let .string(value): return value
            case let .array(blocks):
                return blocks.compactMap { block in
                    let blockType = block["type"]?.stringValue
                    if blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" {
                        return block["text"]?.stringValue
                    }
                    return nil
                }.joined(separator: "\n")
            default:
                return ""
            }
        }
        return message["output"]?.stringValue ?? ""
    }

    private func extractAssistantThinking(from message: JSONValue) -> String {
        guard let content = message["content"] else { return "" }
        guard case let .array(blocks) = content else { return "" }
        return blocks.compactMap { block in
            guard block["type"]?.stringValue == "thinking" else { return nil }
            return block["thinking"]?.stringValue
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
    }
}

private struct ResolvedSkillBlock: Hashable {
    let name: String
    let source: String
    let path: String
    let content: String
}

private enum NativeSubagentError: LocalizedError {
    case emptyTask
    case disabledAgent(String)
    case noProjectUnavailable
    case worktreeFailed(String)
    case continuationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyTask:
            return "Enter a task before running a Deck agent."
        case let .disabledAgent(name):
            return "Agent \(name) is disabled."
        case .noProjectUnavailable:
            return "Deck agents are unavailable for General Chat sessions. Select a project-backed session before launching a Deck agent."
        case let .worktreeFailed(message):
            return "Could not create Deck agent worktree: \(message)"
        case let .continuationUnavailable(message):
            return message
        }
    }
}
