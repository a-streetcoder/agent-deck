import Foundation

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
    private let fileManager = FileManager.default

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(runID: UUID) -> Bool {
        clientsByRunID[runID]?.isRunning == true
    }

    @discardableResult
    func runSingle(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, requestedContext contextOverride: PiSubagentContextMode? = nil, useWorktreeIsolation: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], onCompletion: ((PiSubagentRunRecord) -> Void)? = nil) throws -> PiSubagentRunRecord {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { throw NativeSubagentError.emptyTask }
        guard agent.resolved.disabled != true else { throw NativeSubagentError.disabledAgent(agent.name) }

        let now = Date()
        let runID = UUID()
        let artifactDirectory = try artifactDirectory(for: runID)
        let skillBlocks = resolveSkillBlocks(named: agent.resolved.skills, snapshot: snapshot)
        let resolvedSkillNames = Set(skillBlocks.map(\.name))
        let missingSkillNames = agent.resolved.skills.filter { !resolvedSkillNames.contains($0) }
        let worktreeURL = useWorktreeIsolation ? try createWorktree(for: parentSession, artifactDirectory: artifactDirectory) : nil
        let prompt = buildSystemPrompt(agent: agent, skillBlocks: skillBlocks)
        let promptURL = artifactDirectory.appendingPathComponent("system-prompt.md")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        fileManager.createFile(atPath: artifactDirectory.appendingPathComponent("output.md").path, contents: nil)

        let requestedContext = contextOverride ?? .agentDefault
        let resolvedContext = PiSubagentLaunchPlanner.resolvedContextMode(for: agent, parentSession: parentSession, requestedContext: requestedContext)
        let childSessionDirectory = artifactDirectory.appendingPathComponent("sessions", isDirectory: true)
        var extraArguments: [String] = []
        var contextWarnings: [String] = []
        if resolvedContext == .fork, let parentSessionFile = parentSession.piSessionFile {
            let forkSource = try sanitizedForkContextFile(from: parentSessionFile, artifactDirectory: artifactDirectory)
            extraArguments.append(contentsOf: ["--fork", forkSource.path, "--session-dir", childSessionDirectory.path])
        } else {
            extraArguments.append(contentsOf: ["--session-dir", childSessionDirectory.path])
            if requestedContext == .fork, parentSession.piSessionFile == nil {
                contextWarnings.append("Requested fork context, but the parent Pi session file is not available; launched fresh instead.")
            }
        }
        extraArguments.append(contentsOf: systemPromptArguments(for: agent, prompt: prompt))
        if agent.resolved.inheritProjectContext != true {
            extraArguments.append("--no-context-files")
        }
        var bridgeWarnings: [String] = []
        let wantsSupervisorTool = agent.resolved.tools?.contains("contact_supervisor") == true
        if wantsSupervisorTool {
            if let bridgeURL = try? PiNativeSubagentBridgeExtensions.childExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", bridgeURL.path])
            } else {
                bridgeWarnings.append("contact_supervisor was requested, but \(AppBrand.displayName) could not write the child bridge extension.")
            }
        }
        extraArguments.append(contentsOf: toolArguments(for: agent, includeSupervisorTool: wantsSupervisorTool && bridgeWarnings.isEmpty))
        extraArguments.append(contentsOf: extensionArguments(for: agent))
        if let webURL = try? PiNativeSubagentBridgeExtensions.webAccessExtensionURL() {
            extraArguments.append(contentsOf: ["--extension", webURL.path])
        } else {
            bridgeWarnings.append("\(AppBrand.displayName) could not write the web access extension.")
        }
        if let auditURL = try? PiNativeSubagentBridgeExtensions.systemPromptAuditExtensionURL() {
            extraArguments.append(contentsOf: ["--extension", auditURL.path])
        } else {
            bridgeWarnings.append("\(AppBrand.displayName) could not write the system prompt audit extension.")
        }
        if agent.resolved.inheritSkills != true {
            extraArguments.append("--no-skills")
        }

        let modelSelection = PiSubagentLaunchPlanner.modelSelection(for: agent, parentSession: parentSession)
        let modelArgument = modelSelection.modelArgument
        let modelDisplayName = modelSelection.displayName
        let tools = (agent.resolved.tools ?? []).filter { $0 != "contact_supervisor" || bridgeWarnings.isEmpty }
        let resolvedReadFirstPaths = sanitizedReadFirstPaths(agentReads: agent.resolved.defaultReads ?? [], requestReads: readFirstPaths, projectRoot: URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath))
        try childInput(agent: agent, task: trimmedTask, skillBlocks: skillBlocks, readFirstPaths: resolvedReadFirstPaths).write(
            to: artifactDirectory.appendingPathComponent("input.md"),
            atomically: true,
            encoding: .utf8
        )
        let diagnosticMessages = missingSkillNames.map { "Skill not found: \($0)" } + bridgeWarnings + contextWarnings
        var run = PiSubagentRunRecord(
            id: runID,
            parentSessionID: parentSession.id,
            mode: .single,
            status: .starting,
            agentName: agent.name,
            task: trimmedTask,
            requestedContext: requestedContext,
            resolvedContext: resolvedContext,
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
            parentRepoPath: parentSession.worktreePath ?? parentSession.projectPath,
            baseCommit: useWorktreeIsolation ? currentCommit(in: URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath)) : nil,
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
                requestedContext: requestedContext,
                resolvedContext: resolvedContext,
                model: modelDisplayName,
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
                completedAt: nil,
                createdAt: now,
                updatedAt: now
            ),
            children: nil,
            graphEdges: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            durationMs: nil
        )
        store.upsertSubagentRun(run)
        store.append(.init(
            sessionID: parentSession.id,
            role: .status,
            title: "Subagent Started",
            text: "\(agent.name) is running.\n\nTask: \(trimmedTask)",
            rawJSON: subagentStartedAuditPayload(run: run)
        ))

        let childSessionID = UUID()
        let parentSessionID = parentSession.id
        let childProjectURL = worktreeURL ?? URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath)
        let environment = EnvRuntimeEnvironment().environment(
            projectRoot: childProjectURL,
            extra: [
                "AGENT_DECK_NATIVE_SUBAGENT": "1",
                "AGENT_DECK_SUBAGENT_RUN_ID": runID.uuidString,
                "AGENT_DECK_SUBAGENT_AGENT": agent.name,
                "MCP_DIRECT_TOOLS": mcpDirectTools(for: agent).isEmpty ? "__none__" : mcpDirectTools(for: agent).joined(separator: ",")
            ]
        )
        let client = try PiRPCClient(
            cwd: childProjectURL,
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
                Task { @MainActor [weak self] in self?.handleTermination(exitCode: exitCode, runID: runID, parentSessionID: parentSessionID) }
            }
        )
        clientsByRunID[runID] = client
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
        client.prompt(initialTaskPrompt(agent: agent, task: trimmedTask, artifactDirectory: artifactDirectory, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, useWorktreeIsolation: useWorktreeIsolation, readFirstPaths: resolvedReadFirstPaths, resolvedContext: resolvedContext))
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
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Stopped", text: "Subagent run stopped."))
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
                    }
                    run.child?.sessionFile = run.childPiSessionFile
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
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
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

    private func handleTermination(exitCode: Int32, runID: UUID, parentSessionID: UUID) {
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
            store.append(.init(sessionID: parentSessionID, role: .error, title: "Subagent Failed", text: "Child Pi process exited with code \(exitCode)."))
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
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Completed", text: "\(finalSummary)\(artifactLine)"))
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
        store.append(.init(sessionID: parentSessionID, role: .error, title: "Subagent Failed", text: message))
    }

    private func createWorktree(for parentSession: PiAgentSessionRecord, artifactDirectory: URL) throws -> URL {
        let worktreeURL = artifactDirectory.appendingPathComponent("worktree", isDirectory: true)
        let projectPath = parentSession.worktreePath ?? parentSession.projectPath
        let result: (stdout: String, stderr: String, exitCode: Int32)
        do {
            result = try Self.runGit(arguments: ["-C", projectPath, "worktree", "add", "--detach", worktreeURL.path, "HEAD"], timeout: 30)
        } catch {
            throw NativeSubagentError.worktreeFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeSubagentError.worktreeFailed(message.isEmpty ? "git worktree add failed" : message)
        }
        return worktreeURL
    }

    private func currentCommit(in repositoryURL: URL) -> String? {
        guard let result = try? Self.runGit(arguments: ["-C", repositoryURL.path, "rev-parse", "HEAD"], timeout: 5),
              result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport
            .appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
            .appendingPathComponent("Subagent Runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func outputURL(for runID: UUID, parentSessionID: UUID) -> URL? {
        guard let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), let outputPath = run.outputPath else { return nil }
        return URL(fileURLWithPath: outputPath)
    }

    private func subagentStartedAuditPayload(run: PiSubagentRunRecord) -> String? {
        let payload: [String: Any] = [
            "type": "agent_deck_subagent_started",
            "runID": run.id.uuidString,
            "agent": run.agentName,
            "artifactDirectory": run.artifactDirectory,
            "authoredSystemPromptPath": URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent("system-prompt.md").path,
            "finalSystemPromptPath": URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent("final-system-prompt.md").path
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func sanitizedForkContextFile(from parentSessionFile: String, artifactDirectory: URL) throws -> URL {
        let sourceURL = URL(fileURLWithPath: parentSessionFile)
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        var lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        lines = removeActiveManagedSubagentInvocation(from: lines)
        if let boundaryLine = forkBoundaryLine(parentId: lastSessionEntryID(in: lines)) {
            lines.append(boundaryLine)
        }

        let outputURL = artifactDirectory.appendingPathComponent("fork-context.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private func removeActiveManagedSubagentInvocation(from lines: [String]) -> [String] {
        guard let assistantIndex = lastUnansweredManagedSubagentToolCallIndex(in: lines),
              let userIndex = previousUserMessageIndex(before: assistantIndex, in: lines) else {
            return lines
        }
        var result = lines
        result.removeSubrange(userIndex...assistantIndex)
        return result
    }

    private func lastUnansweredManagedSubagentToolCallIndex(in lines: [String]) -> Int? {
        let parsed = lines.map(jsonObject)
        for index in parsed.indices.reversed() {
            let callIDs = managedSubagentToolCallIDs(in: parsed[index])
            guard !callIDs.isEmpty else { continue }
            let hasResult = parsed[(index + 1)...].contains { object in
                guard messageRole(in: object) == "toolResult",
                      let toolCallID = object?["message"].flatMap({ dictionaryValue($0)?["toolCallId"] as? String }) else {
                    return false
                }
                return callIDs.contains(toolCallID)
            }
            if !hasResult { return index }
        }
        return nil
    }

    private func managedSubagentToolCallIDs(in object: [String: Any]?) -> Set<String> {
        guard messageRole(in: object) == "assistant",
              let message = object?["message"].flatMap(dictionaryValue),
              let content = message["content"] as? [[String: Any]] else {
            return []
        }
        let managedToolNames: Set<String> = ["managed_subagent", "managed_parallel"]
        return Set(content.compactMap { item in
            guard item["type"] as? String == "toolCall",
                  let name = item["name"] as? String,
                  managedToolNames.contains(name),
                  let id = item["id"] as? String else {
                return nil
            }
            return id
        })
    }

    private func previousUserMessageIndex(before index: Int, in lines: [String]) -> Int? {
        guard index > 0 else { return nil }
        for candidate in stride(from: index - 1, through: 0, by: -1) {
            if messageRole(in: jsonObject(from: lines[candidate])) == "user" {
                return candidate
            }
        }
        return nil
    }

    private func forkBoundaryLine(parentId: String?) -> String? {
        var entry: [String: Any] = [
            "type": "custom_message",
            "customType": "agent-deck-native-subagent-boundary",
            "content": "\(AppBrand.displayName) native subagent boundary: all previous forked messages are read-only reference. Do not continue a previous parent tool request or launch another managed_subagent. The next user message is the child subagent's authoritative task.",
            "display": false,
            "id": UUID().uuidString.prefix(8).lowercased(),
            "timestamp": Self.iso8601Formatter.string(from: Date())
        ]
        entry["parentId"] = parentId ?? NSNull()
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        return line
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private func lastSessionEntryID(in lines: [String]) -> String? {
        for line in lines.reversed() {
            if let id = jsonObject(from: line)?["id"] as? String {
                return id
            }
        }
        return nil
    }

    private func messageRole(in object: [String: Any]?) -> String? {
        guard let message = object?["message"].flatMap(dictionaryValue) else { return nil }
        return message["role"] as? String
    }

    private func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func dictionaryValue(_ value: Any) -> [String: Any]? {
        value as? [String: Any]
    }

    private func durationMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func systemPromptArguments(for agent: EffectiveAgentRecord, prompt: String) -> [String] {
        let mode = agent.resolved.systemPromptMode ?? "replace"
        return [mode == "append" ? "--append-system-prompt" : "--system-prompt", prompt]
    }

    private func toolArguments(for agent: EffectiveAgentRecord, includeSupervisorTool: Bool) -> [String] {
        guard let tools = agent.resolved.tools else { return [] }
        let supportedTools = tools.filter { $0 != "contact_supervisor" || includeSupervisorTool }
        guard !supportedTools.isEmpty else { return ["--no-tools"] }
        return ["--tools", supportedTools.joined(separator: ",")]
    }

    private func extensionArguments(for agent: EffectiveAgentRecord) -> [String] {
        var args = ["--no-extensions"]
        for ext in agent.resolved.extensions ?? [] where !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--extension", ext])
        }
        return args
    }

    private func buildSystemPrompt(agent: EffectiveAgentRecord, skillBlocks: [ResolvedSkillBlock]) -> String {
        var sections: [String] = []
        sections.append(nativeBoundaryPrompt(agent: agent))
        if !agent.resolved.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(agent.resolved.systemPrompt)
        }
        if !skillBlocks.isEmpty {
            sections.append(skillBlocks.map { block in
                """
                <skill name=\"\(block.name)\" source=\"\(block.source)\" location=\"\(block.path)\">
                \(block.content)
                </skill>
                """
            }.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private func nativeBoundaryPrompt(agent: EffectiveAgentRecord) -> String {
        var lines = [
            "You are \(AppBrand.displayName) native subagent `\(agent.name)` in a separate child Pi session. Complete only the assigned task; the parent/user remain decision authority.",
            "",
            "Boundaries:",
            "- Do not launch subagents.",
            "- Treat forked context as reference only; do not continue old parent messages."
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
        return lines.joined(separator: "\n")
    }

    private func initialTaskPrompt(agent: EffectiveAgentRecord, task: String, artifactDirectory: URL, expectedOutcome: PiSubagentExpectedOutcome, requestedOutputPath: String?, allowOverwrite: Bool, useWorktreeIsolation: Bool, readFirstPaths: [String], resolvedContext: PiSubagentContextMode) -> String {
        var lines: [String] = []
        lines.append("Native subagent assignment: you are already running as \(AppBrand.displayName) native subagent `\(agent.name)`. The task below is the only active assignment. Do not call `managed_subagent` or continue a previous parent tool request.")
        if resolvedContext == .fork {
            lines.append("Forked context rule: previous messages are read-only background. Ignore earlier requests to launch, retry, inspect, or summarize a subagent unless repeated in the Task section below.")
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

    private func childInput(agent: EffectiveAgentRecord, task: String, skillBlocks: [ResolvedSkillBlock], readFirstPaths: [String]) -> String {
        var sections = [
            """
        # Native subagent input

        Agent: \(agent.name)
        Description: \(agent.resolved.description)
        Skills: \(skillBlocks.map { "\($0.name) [\($0.source)]" }.joined(separator: ", "))

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
        case .project: return "project"
        case .legacyProject: return "legacy project"
        case .global: return "global"
        case .library: return "library"
        case .package: return "package"
        case .builtin: return "builtin"
        case .override: return "override"
        }
    }

    private func handleExtensionUIRequest(_ event: PiAgentRPCEvent, rawLine: String, runID: UUID, parentSessionID: UUID) {
        let title = event.title ?? event.method ?? "extension UI"
        if title == "AGENT_DECK_BRIDGE system_prompt_audit", let requestID = event.id {
            handleSystemPromptAuditBridgeRequest(event, requestID: requestID, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
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
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Needs Decision", text: "Request ID: \(appRequestID)\n\n\(message)"))
        } else {
            store.append(.init(sessionID: parentSessionID, role: .status, title: requestTitle, text: message))
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "Acknowledged.")
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
            let artifactDirectory = URL(fileURLWithPath: run.artifactDirectory)
            let outputURL = artifactDirectory.appendingPathComponent("final-system-prompt.md")
            try? request.systemPrompt.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: "System Prompt Captured", text: "Captured \(request.systemPrompt.count) characters from Pi runtime.", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "System prompt captured.")
    }

    private func supervisorTitle(for kind: PiSubagentSupervisorRequestKind) -> String {
        switch kind {
        case .progressUpdate: return "Subagent Progress"
        case .needDecision: return "Subagent Needs Decision"
        case .interviewRequest: return "Subagent Interview Request"
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
    case worktreeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTask:
            return "Enter a task before running a subagent."
        case let .disabledAgent(name):
            return "Agent \(name) is disabled."
        case let .worktreeFailed(message):
            return "Could not create subagent worktree: \(message)"
        }
    }
}
