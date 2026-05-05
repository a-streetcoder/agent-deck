import Foundation

@MainActor
final class PiSubagentRunService {
    private let store: PiAgentSessionStore
    private var clientsByRunID: [UUID: PiRPCClient] = [:]
    private var finalTextByRunID: [UUID: String] = [:]
    private var completionHandlersByRunID: [UUID: (PiSubagentRunRecord) -> Void] = [:]
    private var supervisorTimeoutTasksByRequestID: [String: Task<Void, Never>] = [:]
    private let fileManager = FileManager.default

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(runID: UUID) -> Bool {
        clientsByRunID[runID]?.isRunning == true
    }

    @discardableResult
    func runSingle(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, requestedContext contextOverride: PiSubagentContextMode? = nil, useWorktreeIsolation: Bool = false, onCompletion: ((PiSubagentRunRecord) -> Void)? = nil) throws -> PiSubagentRunRecord {
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
        try childInput(agent: agent, task: trimmedTask, skillBlocks: skillBlocks).write(
            to: artifactDirectory.appendingPathComponent("input.md"),
            atomically: true,
            encoding: .utf8
        )

        let requestedContext = contextOverride ?? .agentDefault
        let resolvedContext = resolvedContextMode(for: agent, parentSession: parentSession, requestedContext: requestedContext)
        var extraArguments: [String] = []
        var contextWarnings: [String] = []
        if resolvedContext == .fork, let parentSessionFile = parentSession.piSessionFile {
            extraArguments.append(contentsOf: ["--fork", parentSessionFile])
        } else {
            extraArguments.append(contentsOf: ["--session-dir", artifactDirectory.appendingPathComponent("sessions", isDirectory: true).path])
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
                bridgeWarnings.append("contact_supervisor was requested, but Pi Manager could not write the child bridge extension.")
            }
        }
        extraArguments.append(contentsOf: toolArguments(for: agent, includeSupervisorTool: wantsSupervisorTool && bridgeWarnings.isEmpty))
        extraArguments.append(contentsOf: extensionArguments(for: agent))
        if agent.resolved.inheritSkills != true {
            extraArguments.append("--no-skills")
        }

        let modelArgument = modelArgument(for: agent)
        let tools = (agent.resolved.tools ?? []).filter { $0 != "contact_supervisor" || bridgeWarnings.isEmpty }
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
            model: modelArgument,
            thinking: agent.resolved.thinking,
            tools: tools,
            skills: agent.resolved.skills,
            chainName: nil,
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
                model: modelArgument,
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
        store.append(.init(sessionID: parentSession.id, role: .status, title: "Subagent Started", text: "\(agent.name) is running.\n\nTask: \(trimmedTask)"))

        let childSessionID = UUID()
        let client = try PiRPCClient(
            cwd: worktreeURL ?? URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath),
            modelArgument: modelArgument,
            extraArguments: extraArguments,
            environment: [
                "PI_MANAGER_NATIVE_SUBAGENT": "1",
                "PI_MANAGER_SUBAGENT_RUN_ID": runID.uuidString,
                "PI_MANAGER_SUBAGENT_AGENT": agent.name
            ],
            onEvent: { [weak self] rawLine, event in
                DispatchQueue.main.async { self?.handle(rawLine: rawLine, event: event, runID: runID, parentSessionID: parentSession.id) }
            },
            onStderr: { [weak self] line in
                DispatchQueue.main.async { self?.handle(stderr: line, runID: runID, parentSessionID: parentSession.id) }
            },
            onTermination: { [weak self] exitCode in
                DispatchQueue.main.async { self?.handleTermination(exitCode: exitCode, runID: runID, parentSessionID: parentSession.id) }
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
        client.prompt(initialTaskPrompt(agent: agent, task: trimmedTask, artifactDirectory: artifactDirectory))
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

    func stop(runID: UUID, parentSessionID: UUID) {
        guard let client = clientsByRunID.removeValue(forKey: runID) else { return }
        cancelSupervisorTimeouts(for: runID, parentSessionID: parentSessionID)
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
        store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Stopped", text: "Subagent run stopped."))
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
                    run.child?.sessionFile = run.childPiSessionFile
                }
            }
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            let toolName = event.toolName ?? "tool"
            let toolText = event.args?.compactDescription ?? event.partialResult?.compactDescription ?? event.result?.compactDescription ?? event.error?.compactDescription ?? event.type ?? "tool"
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .tool, title: "Tool: \(toolName)", text: toolText, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.child?.currentTool = event.type == "tool_execution_end" ? nil : toolName
                run.child?.updatedAt = Date()
            }
        case "message_end":
            handleMessageEnd(event, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
        case "extension_ui_request":
            handleExtensionUIRequest(event, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
        case "turn_end", "agent_end":
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
        default:
            if let type = event.type, type != "message_update" {
                store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .raw, title: type, text: event.data?.compactDescription ?? rawLine, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            }
        }
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
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let transcriptRole = PiAgentTranscriptRole(rawValue: role) ?? .raw
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: transcriptRole, title: role.capitalized, text: text, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        }
        guard role == "assistant" else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", projectPath, "worktree", "add", "--detach", worktreeURL.path, "HEAD"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeSubagentError.worktreeFailed(message?.isEmpty == false ? message! : "git worktree add failed")
        }
        return worktreeURL
    }

    private func currentCommit(in repositoryURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repositoryURL.path, "rev-parse", "HEAD"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func artifactDirectory(for runID: UUID) throws -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport
            .appendingPathComponent("Pi Manager", isDirectory: true)
            .appendingPathComponent("Subagent Runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func outputURL(for runID: UUID, parentSessionID: UUID) -> URL? {
        guard let run = store.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), let outputPath = run.outputPath else { return nil }
        return URL(fileURLWithPath: outputPath)
    }

    private func durationMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func resolvedContextMode(for agent: EffectiveAgentRecord, parentSession: PiAgentSessionRecord, requestedContext: PiSubagentContextMode) -> PiSubagentContextMode {
        switch requestedContext {
        case .fresh:
            return .fresh
        case .fork:
            return parentSession.piSessionFile == nil ? .fresh : .fork
        case .agentDefault:
            if agent.resolved.defaultContext == "fork", parentSession.piSessionFile != nil { return .fork }
            if agent.resolved.defaultContext == "fresh" { return .fresh }
            return .fresh
        }
    }

    private func modelArgument(for agent: EffectiveAgentRecord) -> String? {
        guard let model = agent.resolved.model, !model.isEmpty else { return nil }
        guard let thinking = agent.resolved.thinking, !thinking.isEmpty, thinking != "off" else { return model }
        let suffixes = ["off", "minimal", "low", "medium", "high", "xhigh"]
        if let suffix = model.split(separator: ":").last, suffixes.contains(String(suffix)) { return model }
        return "\(model):\(thinking)"
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
        """
        You are a Pi Manager native subagent named `\(agent.name)`.

        You are running in a separate child Pi session managed by Pi Manager. Complete only the assigned task. The parent session and user remain the decision authority.

        Boundaries:
        - Do not launch or propose additional subagents.
        - Treat inherited/forked conversation, if present, as reference-only context.
        - Do not continue old parent messages as if they were addressed to you.
        - If a new product, architecture, or scope decision is required and no supervisor tool is available, stop and report the decision needed in your final response.
        - Do not send routine completion handoffs through coordination tools. Return your final result normally.
        - Prefer narrow, correct changes over broad rewrites.
        """
    }

    private func initialTaskPrompt(agent: EffectiveAgentRecord, task: String, artifactDirectory: URL) -> String {
        var lines: [String] = []
        if let reads = agent.resolved.defaultReads, !reads.isEmpty {
            lines.append("Read these files first if they exist and are relevant: \(reads.joined(separator: ", "))")
        }
        if let output = agent.resolved.output, !output.isEmpty {
            lines.append("Agent default output is `\(output)`, but Pi Manager native runs save the final result to the app artifact directory unless the task explicitly asks you to edit a project file.")
        }
        lines.append("Artifact directory: \(artifactDirectory.path)")
        lines.append("Task:\n\(task)")
        return lines.joined(separator: "\n\n")
    }

    private func childInput(agent: EffectiveAgentRecord, task: String, skillBlocks: [ResolvedSkillBlock]) -> String {
        """
        # Native subagent input

        Agent: \(agent.name)
        Description: \(agent.resolved.description)
        Skills: \(skillBlocks.map { "\($0.name) [\($0.source)]" }.joined(separator: ", "))

        ## Task

        \(task)
        """
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
        guard title == "PI_MANAGER_BRIDGE contact_supervisor", let requestID = event.id else {
            store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: title, text: event.message?.compactDescription ?? "Extension UI request", rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
            return
        }
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            clientsByRunID[runID]?.respondToExtensionUI(id: requestID, value: "Pi Manager could not parse supervisor request.")
            return
        }
        let requestKindRaw = json["requestKind"] as? String ?? "progress_update"
        let kind = PiSubagentSupervisorRequestKind(rawValue: requestKindRaw) ?? .progressUpdate
        let message = json["message"] as? String ?? ""
        let requestTitle = json["title"] as? String ?? supervisorTitle(for: kind)
        let now = Date()
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
            createdAt: now,
            updatedAt: now
        )
        store.upsertSupervisorRequest(request)
        store.appendSubagentTranscript(.init(sessionID: parentSessionID, role: .status, title: "Supervisor · \(kind.rawValue)", text: message, rawJSON: rawLine), runID: runID, parentSessionID: parentSessionID)
        if kind.isBlocking {
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.status = .blocked
                run.child?.status = .blocked
                run.updatedAt = now
                run.child?.updatedAt = now
            }
            scheduleSupervisorTimeout(requestID: appRequestID, runID: runID, parentSessionID: parentSessionID)
            store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Needs Decision", text: message))
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
