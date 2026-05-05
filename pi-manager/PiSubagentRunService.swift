import Foundation

@MainActor
final class PiSubagentRunService {
    private let store: PiAgentSessionStore
    private var clientsByRunID: [UUID: PiRPCClient] = [:]
    private var finalTextByRunID: [UUID: String] = [:]
    private let fileManager = FileManager.default

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(runID: UUID) -> Bool {
        clientsByRunID[runID]?.isRunning == true
    }

    @discardableResult
    func runSingle(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String) throws -> PiSubagentRunRecord {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { throw NativeSubagentError.emptyTask }
        guard agent.resolved.disabled != true else { throw NativeSubagentError.disabledAgent(agent.name) }

        let now = Date()
        let runID = UUID()
        let artifactDirectory = try artifactDirectory(for: runID)
        let skillBlocks = resolveSkillBlocks(named: agent.resolved.skills, snapshot: snapshot)
        let prompt = buildSystemPrompt(agent: agent, skillBlocks: skillBlocks)
        let promptURL = artifactDirectory.appendingPathComponent("system-prompt.md")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        try childInput(agent: agent, task: trimmedTask, skillBlocks: skillBlocks).write(
            to: artifactDirectory.appendingPathComponent("input.md"),
            atomically: true,
            encoding: .utf8
        )

        let requestedContext = PiSubagentContextMode.agentDefault
        let resolvedContext = resolvedContextMode(for: agent, parentSession: parentSession)
        var extraArguments: [String] = []
        if resolvedContext == .fork, let parentSessionFile = parentSession.piSessionFile {
            extraArguments.append(contentsOf: ["--fork", parentSessionFile])
        } else {
            extraArguments.append(contentsOf: ["--session-dir", artifactDirectory.appendingPathComponent("sessions", isDirectory: true).path])
        }
        extraArguments.append(contentsOf: systemPromptArguments(for: agent, prompt: prompt))
        if agent.resolved.inheritProjectContext != true {
            extraArguments.append("--no-context-files")
        }
        extraArguments.append(contentsOf: toolArguments(for: agent))
        extraArguments.append(contentsOf: extensionArguments(for: agent))
        if agent.resolved.inheritSkills != true {
            extraArguments.append("--no-skills")
        }

        let modelArgument = modelArgument(for: agent)
        let tools = (agent.resolved.tools ?? []).filter { $0 != "contact_supervisor" }
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
            artifactDirectory: artifactDirectory.path,
            outputPath: artifactDirectory.appendingPathComponent("output.md").path,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: nil,
            child: PiSubagentChildRecord(
                id: UUID(),
                runID: runID,
                index: 0,
                agentName: agent.name,
                status: .starting,
                currentTool: nil,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                toolCount: nil,
                sessionFile: nil,
                outputPath: artifactDirectory.appendingPathComponent("output.md").path,
                error: nil,
                createdAt: now,
                updatedAt: now
            ),
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
        store.upsertSubagentRun(run)
        store.append(.init(sessionID: parentSession.id, role: .status, title: "Subagent Started", text: "\(agent.name) is running.\n\nTask: \(trimmedTask)"))

        let childSessionID = UUID()
        let client = try PiRPCClient(
            cwd: URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath),
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
        run.childSessionID = childSessionID
        run.launchCommand = client.launchCommand
        run.status = .running
        run.child?.status = .running
        store.upsertSubagentRun(run)
        client.getState()
        client.prompt(initialTaskPrompt(agent: agent, task: trimmedTask, artifactDirectory: artifactDirectory))
        return run
    }

    func stop(runID: UUID, parentSessionID: UUID) {
        guard let client = clientsByRunID.removeValue(forKey: runID) else { return }
        client.stop()
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = .stopped
            run.child?.status = .stopped
            run.completedAt = Date()
        }
        store.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Stopped", text: "Subagent run stopped."))
    }

    private func handle(rawLine: String, event: PiAgentRPCEvent?, runID: UUID, parentSessionID: UUID) {
        guard let event else { return }
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
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.child?.currentTool = event.type == "tool_execution_end" ? nil : toolName
                run.child?.updatedAt = Date()
            }
        case "message_end":
            handleMessageEnd(event, rawLine: rawLine, runID: runID, parentSessionID: parentSessionID)
        case "turn_end", "agent_end":
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
        default:
            break
        }
    }

    private func handle(stderr line: String, runID: UUID, parentSessionID: UUID) {
        guard !line.localizedCaseInsensitiveContains("ready for input") else { return }
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.error = [run.error, line].compactMap { $0 }.joined(separator: "\n")
        }
    }

    private func handleTermination(exitCode: Int32, runID: UUID, parentSessionID: UUID) {
        clientsByRunID[runID] = nil
        if exitCode == 0 {
            completeIfNeeded(runID: runID, parentSessionID: parentSessionID)
        } else {
            store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                run.status = .failed
                run.child?.status = .failed
                run.error = "Child Pi process exited with code \(exitCode)."
                run.child?.error = run.error
                run.completedAt = Date()
            }
            store.append(.init(sessionID: parentSessionID, role: .error, title: "Subagent Failed", text: "Child Pi process exited with code \(exitCode)."))
        }
    }

    private func handleMessageEnd(_ event: PiAgentRPCEvent, rawLine: String, runID: UUID, parentSessionID: UUID) {
        guard let message = event.message else { return }
        let role = message["role"]?.stringValue ?? "assistant"
        guard role == "assistant" else { return }
        let text = extractAssistantText(from: message)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        finalTextByRunID[runID] = text
        store.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.summary = text
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
            run.status = .completed
            run.child?.status = .completed
            run.completedAt = Date()
            run.summary = finalSummary
            outputPath = run.outputPath
            shouldAppend = true
        }
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

    private func resolvedContextMode(for agent: EffectiveAgentRecord, parentSession: PiAgentSessionRecord) -> PiSubagentContextMode {
        if agent.resolved.defaultContext == "fork", parentSession.piSessionFile != nil { return .fork }
        if agent.resolved.defaultContext == "fresh" { return .fresh }
        return .fresh
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

    private func toolArguments(for agent: EffectiveAgentRecord) -> [String] {
        guard let tools = agent.resolved.tools else { return [] }
        let supportedTools = tools.filter { $0 != "contact_supervisor" }
        guard !supportedTools.isEmpty else { return ["--no-tools"] }
        return ["--tools", supportedTools.joined(separator: ",")]
    }

    private func extensionArguments(for agent: EffectiveAgentRecord) -> [String] {
        guard let extensions = agent.resolved.extensions else { return [] }
        var args = ["--no-extensions"]
        for ext in extensions where !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                <skill name=\"\(block.name)\" location=\"\(block.path)\">
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
        Skills: \(skillBlocks.map(\.name).joined(separator: ", "))

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
            return ResolvedSkillBlock(name: name, path: record.filePath, content: content)
        }
    }

    private func skillMarkdown(for record: SkillRecord) -> String {
        if let raw = try? String(contentsOfFile: record.filePath, encoding: .utf8), !raw.isEmpty { return raw }
        return record.body
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
    let path: String
    let content: String
}

private enum NativeSubagentError: LocalizedError {
    case emptyTask
    case disabledAgent(String)

    var errorDescription: String? {
        switch self {
        case .emptyTask:
            return "Enter a task before running a subagent."
        case let .disabledAgent(name):
            return "Agent \(name) is disabled."
        }
    }
}
