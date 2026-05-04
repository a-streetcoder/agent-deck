import Foundation

@MainActor
final class PiAgentRunnerService {
    private let store: PiAgentSessionStore
    private var clientsBySessionID: [UUID: PiRPCClient] = [:]
    private var assistantEntryIDsBySessionID: [UUID: UUID] = [:]
    private var assistantTextBySessionID: [UUID: String] = [:]
    private var thinkingEntryIDsBySessionID: [UUID: UUID] = [:]
    private var thinkingTextBySessionID: [UUID: String] = [:]
    private var toolEntryIDsByCallID: [String: UUID] = [:]
    private var compactionEntryIDsBySessionID: [UUID: UUID] = [:]
    private var pendingCompactionInstructionsBySessionID: [UUID: String] = [:]
    private var streamFlushTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    var onTurnFinished: ((UUID) -> Void)?

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(sessionID: UUID) -> Bool {
        clientsBySessionID[sessionID]?.isRunning == true
    }

    func startProjectSession(project: DiscoveredProject, initialInstruction: String) {
        let title = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? "Project agent · \(project.name)"
        let session = store.createSession(
            kind: .project,
            title: title.isEmpty ? "New Agent Session" : String(title.prefix(80)),
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        let prompt = PiIssuePromptBuilder.projectPrompt(project: project, initialInstruction: initialInstruction)
        start(session: session, projectURL: project.url, initialPrompt: prompt)
    }

    func startIssueSession(detail: GitHubIssueDetail, project: DiscoveredProject) {
        let session = store.createSession(
            kind: .issue,
            title: detail.item.title,
            project: project,
            repository: detail.item.repository,
            issueNumber: detail.item.number,
            issueURL: detail.item.url
        )
        let prompt = PiIssuePromptBuilder.issuePrompt(detail: detail, project: project)
        start(session: session, projectURL: project.url, initialPrompt: prompt)
    }

    func resume(session: PiAgentSessionRecord, initialPrompt: String? = nil, images: [PiAgentImageAttachment] = []) {
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        // If Pi has already created a session file, always resume it before sending a new prompt.
        // Otherwise an idle follow-up (or a model change followed by Send) starts a fresh Pi session
        // and the chat appears to lose context.
        let canResumePiSession = session.piSessionFile != nil
        start(session: session, projectURL: projectURL, initialPrompt: initialPrompt, initialImages: images, resumeExisting: canResumePiSession)
    }

    func send(_ text: String, mode: PiAgentInputMode, to sessionID: UUID, images: [PiAgentImageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let message = userMessage(trimmed, images: images)
        guard let client = clientsBySessionID[sessionID] else {
            store.append(.init(sessionID: sessionID, role: .error, title: "Not Running", text: "Resume the session before sending a message."))
            return
        }
        let isStreaming = store.sessions.first(where: { $0.id == sessionID })?.status.isActive == true
        let effectiveMode: PiAgentInputMode = isStreaming ? .steer : mode
        store.append(.init(sessionID: sessionID, role: .user, title: transcriptTitle(for: effectiveMode, isStreaming: isStreaming), text: transcriptText(message, images: images)))
        switch effectiveMode {
        case .prompt:
            client.prompt(message, images: images)
        case .steer:
            client.prompt(message, images: images, streamingBehavior: "steer")
        case .followUp:
            client.prompt(message, images: images, streamingBehavior: "followUp")
        }
        mark(sessionID, status: .running, error: nil)
    }

    func syncSessionName(for sessionID: UUID) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), session.isTitleUserEdited else { return }
        let name = session.displayTitle
        if let client = clientsBySessionID[sessionID], client.isRunning {
            client.setSessionName(name)
            return
        }
        guard let sessionFile = session.piSessionFile else { return }
        appendSessionInfo(name: name, to: sessionFile)
    }

    func respondToExtensionUI(sessionID: UUID, requestID: String, value: String) {
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: value)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func confirmExtensionUI(sessionID: UUID, requestID: String, confirmed: Bool) {
        clientsBySessionID[sessionID]?.confirmExtensionUI(id: requestID, confirmed: confirmed)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func cancelExtensionUI(sessionID: UUID, requestID: String) {
        clientsBySessionID[sessionID]?.cancelExtensionUI(id: requestID)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func stop(sessionID: UUID) {
        streamFlushTasksBySessionID[sessionID]?.cancel()
        streamFlushTasksBySessionID[sessionID] = nil
        guard let client = clientsBySessionID.removeValue(forKey: sessionID) else { return }
        client.stop()
        store.append(.init(sessionID: sessionID, role: .status, title: "Stopped", text: "Stop requested. Pi Agent received abort and the process is terminating."))
        mark(sessionID, status: .stopped, error: nil)
    }

    func refreshPiControls(sessionID: UUID) {
        guard let client = clientsBySessionID[sessionID] else { return }
        client.getState()
        client.getAvailableModels()
        client.getSessionStats()
    }

    func setModel(sessionID: UUID, provider: String?, modelID: String?) {
        store.updateSession(sessionID) { record in
            record.modelOverrideProvider = provider
            record.modelOverrideID = modelID
        }
        guard let provider, let modelID, let client = clientsBySessionID[sessionID] else { return }
        client.setModel(provider: provider, modelID: modelID)
    }

    func cycleModel(sessionID: UUID) {
        guard let client = clientsBySessionID[sessionID] else { return }
        client.cycleModel()
    }

    func setThinkingLevel(sessionID: UUID, level: String) {
        store.updateSession(sessionID) { $0.thinkingLevel = level }
        guard let client = clientsBySessionID[sessionID] else { return }
        client.setThinkingLevel(level)
    }

    func compact(session: PiAgentSessionRecord, customInstructions: String? = nil) {
        let messageCount = store.transcriptsBySessionID[session.id]?.filter { $0.role == .user || $0.role == .assistant }.count ?? 0
        guard messageCount >= 2 else {
            store.append(.init(sessionID: session.id, role: .status, title: "Compaction", text: "Nothing to compact."))
            return
        }
        let instructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let client = clientsBySessionID[session.id] {
            client.compact(customInstructions: instructions.isEmpty ? nil : instructions)
        } else {
            pendingCompactionInstructionsBySessionID[session.id] = instructions
            resume(session: session)
        }
    }

    func cycleThinkingLevel(sessionID: UUID) {
        guard let client = clientsBySessionID[sessionID] else { return }
        client.cycleThinkingLevel()
    }

    func stopAll() {
        for id in Array(clientsBySessionID.keys) {
            stop(sessionID: id)
        }
    }

    private func start(session: PiAgentSessionRecord, projectURL: URL, initialPrompt: String?, initialImages: [PiAgentImageAttachment] = [], resumeExisting: Bool = false) {
        stop(sessionID: session.id)
        mark(session.id, status: .starting, error: nil)
        let trimmedInitialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInitialPrompt.isEmpty || !initialImages.isEmpty {
            let message = userMessage(trimmedInitialPrompt, images: initialImages)
            store.append(.init(sessionID: session.id, role: .user, title: "Initial Prompt", text: transcriptText(message, images: initialImages)))
        }

        do {
            let client = try PiRPCClient(
                cwd: projectURL,
                sessionFile: resumeExisting ? session.piSessionFile : nil,
                provider: session.modelOverrideProvider,
                model: session.modelOverrideID,
                onEvent: { [weak self] rawLine, event in
                    DispatchQueue.main.async { self?.handle(rawLine: rawLine, event: event, sessionID: session.id) }
                },
                onStderr: { [weak self] line in
                    DispatchQueue.main.async { self?.handle(stderr: line, sessionID: session.id) }
                },
                onTermination: { [weak self] exitCode in
                    DispatchQueue.main.async { self?.handleTermination(exitCode: exitCode, sessionID: session.id) }
                }
            )
            clientsBySessionID[session.id] = client
            store.updateSession(session.id) { record in
                record.launchCommand = client.launchCommand
                record.status = .running
            }
            client.getState()
            client.getAvailableModels()
            if session.isTitleUserEdited {
                client.setSessionName(session.displayTitle)
            }
            if let thinkingLevel = session.thinkingLevel, !thinkingLevel.isEmpty {
                client.setThinkingLevel(thinkingLevel)
            }
            if !trimmedInitialPrompt.isEmpty || !initialImages.isEmpty {
                let message = userMessage(trimmedInitialPrompt, images: initialImages)
                client.prompt(message, images: initialImages)
            } else if let instructions = pendingCompactionInstructionsBySessionID.removeValue(forKey: session.id) {
                client.compact(customInstructions: instructions.isEmpty ? nil : instructions)
            } else {
                client.getMessages()
            }
        } catch {
            mark(session.id, status: .failed, error: error.localizedDescription)
            store.append(.init(sessionID: session.id, role: .error, title: "Launch Failed", text: error.localizedDescription))
        }
    }

    private func appendSessionInfo(name: String, to sessionFile: String) {
        let url = URL(fileURLWithPath: sessionFile)
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        var parentID: String?
        var existingIDs = Set<String>()
        var hasSessionHeader = false
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["type"] as? String == "session" {
                hasSessionHeader = true
            }
            if let id = object["id"] as? String {
                existingIDs.insert(id)
                if object["type"] as? String != "session" {
                    parentID = id
                }
            }
        }
        guard hasSessionHeader else { return }

        let entryID = makeShortSessionEntryID(excluding: existingIDs)
        var entry: [String: Any] = [
            "type": "session_info",
            "id": entryID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "name": name
        ]
        entry["parentId"] = parentID ?? NSNull()
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            let prefix = content.hasSuffix("\n") || content.isEmpty ? "" : "\n"
            handle.write(Data((prefix + line + "\n").utf8))
        }
    }

    private func makeShortSessionEntryID(excluding existingIDs: Set<String>) -> String {
        for _ in 0..<100 {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            if !existingIDs.contains(id) { return String(id) }
        }
        return UUID().uuidString.lowercased()
    }

    private func userMessage(_ text: String, images: [PiAgentImageAttachment]) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Please inspect the attached image(s)." : text
        guard !images.isEmpty else { return base }
        let fileTags = images.map { image in
            "<file name=\"\(image.fileReference ?? image.name)\">\(image.dimensionNote ?? "")</file>"
        }.joined(separator: "\n")
        return "\(base)\n\n\(fileTags)"
    }

    private func transcriptTitle(for mode: PiAgentInputMode, isStreaming: Bool) -> String {
        guard isStreaming else { return "Prompt" }
        switch mode {
        case .prompt, .steer: return "Steering"
        case .followUp: return "Queued follow-up"
        }
    }

    private func transcriptText(_ text: String, images: [PiAgentImageAttachment]) -> String {
        let visibleText = visibleUserText(text)
        guard !images.isEmpty else { return visibleText }
        let imageList = images.map { image in
            "- <image name=\"\(image.name)\" mimeType=\"\(image.mimeType)\" size=\"\(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))\"></image>"
        }.joined(separator: "\n")
        return "\(visibleText)\n\nAttached images:\n\(imageList)"
    }

    private func visibleUserText(_ text: String) -> String {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var attachments: [String] = []
        var stripped = text
        for match in regex.matches(in: text, range: range).reversed() {
            let path = (text as NSString).substring(with: match.range(at: 1))
            attachments.append(URL(fileURLWithPath: path).lastPathComponent)
            if let range = Range(match.range, in: stripped) {
                stripped.removeSubrange(range)
            }
        }
        let base = stripped.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let fileList = attachments.map { "- \($0)" }.joined(separator: "\n")
        return [base, "Attached files:\n\(fileList)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func handle(stderr: String, sessionID: UUID) {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isIgnorableStderr(trimmed) else { return }
        if isConnectionError(trimmed) {
            let message = normalizedConnectionError(trimmed)
            store.append(.init(sessionID: sessionID, role: .error, title: "Connection Error", text: message))
        } else {
            store.append(.init(sessionID: sessionID, role: .stderr, title: "stderr", text: trimmed))
        }
    }

    private func isIgnorableStderr(_ text: String) -> Bool {
        text.contains(";notify;Pi;") || text.localizedCaseInsensitiveContains("ready for input")
    }

    private func isConnectionError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("websocket")
            || lower.contains("socket hang up")
            || lower.contains("econnreset")
            || lower.contains("connection reset")
            || lower.contains("connection closed")
            || lower.contains("network error")
    }

    private func normalizedConnectionError(_ text: String) -> String {
        text
            .replacingOccurrences(of: "WebSocket error:", with: "WebSocket error ·")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func handle(rawLine: String, event: PiAgentRPCEvent?, sessionID: UUID) {
        guard let event else {
            store.append(.init(sessionID: sessionID, role: .raw, title: "Raw Output", text: rawLine))
            return
        }

        switch event.type {
        case "response":
            handleResponse(event, rawLine: rawLine, sessionID: sessionID)
        case "agent_start", "turn_start":
            mark(sessionID, status: .running, error: nil)
            if event.type == "turn_start" {
                let entryID = UUID()
                assistantEntryIDsBySessionID[sessionID] = entryID
                assistantTextBySessionID[sessionID] = ""
                thinkingEntryIDsBySessionID[sessionID] = nil
                thinkingTextBySessionID[sessionID] = nil
                store.upsert(.init(id: entryID, sessionID: sessionID, role: .assistant, title: "Assistant", text: "", rawJSON: nil))
            }
        case "agent_end", "turn_end":
            mark(sessionID, status: .idle, error: nil)
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
            onTurnFinished?(sessionID)
        case "message_update":
            handleMessageUpdate(event, rawLine: rawLine, sessionID: sessionID)
        case "message_end":
            handleMessageEnd(event, rawLine: rawLine, sessionID: sessionID)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            handleToolExecution(event, rawLine: rawLine, sessionID: sessionID)
        case "extension_ui_request":
            handleExtensionUIRequest(event, rawLine: rawLine, sessionID: sessionID)
        case "queue_update":
            handleQueueUpdate(event, sessionID: sessionID)
        case "compaction_start", "compaction_end":
            handleCompaction(event, rawLine: rawLine, sessionID: sessionID)
        case "auto_retry_start", "auto_retry_end":
            handleRetry(event, rawLine: rawLine, sessionID: sessionID)
        default:
            if let entry = transcriptEntry(from: event, rawLine: rawLine, sessionID: sessionID) {
                store.append(entry)
            }
        }
    }

    private func handleResponse(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        if event.success == false {
            let message = event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine
            mark(sessionID, status: .failed, error: message)
            store.append(.init(sessionID: sessionID, role: .error, title: event.command ?? "RPC Error", text: message, rawJSON: rawLine))
            return
        }

        if event.command == "get_state", let data = event.data {
            applyState(data, to: sessionID)
            return
        }

        if event.command == "get_available_models", let data = event.data {
            store.updateSession(sessionID) { record in
                record.availableModels = parseModelOptions(from: data["models"] ?? data)
            }
            return
        }

        if event.command == "set_model" || event.command == "cycle_model", let data = event.data {
            store.updateSession(sessionID) { record in
                if let modelObject = data["model"] ?? (data["id"] == nil ? nil : data) {
                    updateModelFields(on: &record, from: modelObject, useAsOverride: true)
                }
                if let thinkingLevel = data["thinkingLevel"]?.stringValue {
                    record.thinkingLevel = thinkingLevel
                }
            }
            clientsBySessionID[sessionID]?.getState()
            return
        }

        if event.command == "set_thinking_level" || event.command == "cycle_thinking_level", let data = event.data {
            store.updateSession(sessionID) { record in
                record.thinkingLevel = data["level"]?.stringValue ?? data["thinkingLevel"]?.stringValue ?? record.thinkingLevel
            }
            clientsBySessionID[sessionID]?.getState()
            return
        }

        if event.command == "compact" {
            store.updateSession(sessionID) {
                $0.isCompacting = false
                $0.contextTokens = nil
                $0.contextWindow = nil
                $0.contextPercent = nil
            }
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
            return
        }

        if event.command == "get_session_stats", let data = event.data {
            store.updateSession(sessionID) { record in
                record.lastSummary = data.compactDescription
                record.inputTokens = data["tokens"]?["input"]?.numberValue.map(Int.init)
                record.outputTokens = data["tokens"]?["output"]?.numberValue.map(Int.init)
                record.cacheReadTokens = data["tokens"]?["cacheRead"]?.numberValue.map(Int.init)
                record.cacheWriteTokens = data["tokens"]?["cacheWrite"]?.numberValue.map(Int.init)
                record.totalTokens = data["tokens"]?["total"]?.numberValue.map(Int.init)
                record.toolCalls = data["toolCalls"]?.numberValue.map(Int.init)
                record.toolResults = data["toolResults"]?.numberValue.map(Int.init)
                record.cost = data["cost"]?.numberValue
                if let contextUsage = data["contextUsage"] {
                    record.contextTokens = contextUsage["tokens"]?.numberValue.map(Int.init)
                    record.contextWindow = contextUsage["contextWindow"]?.numberValue.map(Int.init)
                    record.contextPercent = contextUsage["percent"]?.numberValue
                } else {
                    record.contextTokens = nil
                    record.contextWindow = nil
                    record.contextPercent = nil
                }
            }
        }
    }

    private func applyState(_ data: JSONValue, to sessionID: UUID) {
        store.updateSession(sessionID) { record in
            record.piSessionFile = data["sessionFile"]?.stringValue ?? record.piSessionFile
            record.piSessionId = data["sessionId"]?.stringValue ?? record.piSessionId
            if let modelObject = data["model"] {
                updateModelFields(on: &record, from: modelObject, useAsOverride: false)
            }
            record.thinkingLevel = data["thinkingLevel"]?.stringValue ?? record.thinkingLevel
            if let streaming = data["isStreaming"]?.compactDescription, streaming == "true" {
                record.status = .running
            } else if record.status.isActive {
                record.status = .idle
            }
        }
    }

    private func updateModelFields(on record: inout PiAgentSessionRecord, from modelObject: JSONValue, useAsOverride: Bool) {
        let provider = modelObject["provider"]?.stringValue ?? modelObject["providerId"]?.stringValue
        let modelID = modelObject["id"]?.stringValue ?? modelObject["modelId"]?.stringValue ?? modelObject["model"]?.stringValue
        record.modelProvider = provider ?? record.modelProvider
        record.model = modelID ?? record.model
        if useAsOverride {
            record.modelOverrideProvider = provider ?? record.modelOverrideProvider
            record.modelOverrideID = modelID ?? record.modelOverrideID
        }
    }

    private func parseModelOptions(from value: JSONValue) -> [PiAgentModelOption] {
        guard case let .array(models) = value else { return [] }
        return models.compactMap { model in
            let provider = model["provider"]?.stringValue ?? model["providerId"]?.stringValue
            let id = model["id"]?.stringValue ?? model["modelId"]?.stringValue ?? model["model"]?.stringValue
            guard let provider, let id else { return nil }
            let contextWindow: Int?
            if case let .number(value)? = model["contextWindow"] {
                contextWindow = Int(value)
            } else {
                contextWindow = nil
            }
            let supportsThinking = model["reasoning"]?.boolValue ?? model["supportsThinking"]?.boolValue
            let supportedThinkingLevels: [String]? = {
                if let levels = stringArray(from: model["supportedThinkingLevels"]) { return levels }
                guard supportsThinking == true else { return supportsThinking == false ? ["off"] : nil }
                return supportsXhigh(provider: provider, modelID: id) ? ["off", "minimal", "low", "medium", "high", "xhigh"] : ["off", "minimal", "low", "medium", "high"]
            }()
            let supportsImages = model["supportsImages"]?.boolValue ?? model["image"]?.boolValue
            return PiAgentModelOption(
                provider: provider,
                id: id,
                name: model["name"]?.stringValue,
                contextWindow: contextWindow,
                supportsThinking: supportsThinking,
                supportedThinkingLevels: supportedThinkingLevels,
                supportsImages: supportsImages
            )
        }
    }

    private func stringArray(from value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
    }

    private func supportsXhigh(provider: String, modelID: String) -> Bool {
        PiModelCapability.supportsXhigh(modelID: modelID)
    }

    private func handleMessageUpdate(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        guard let assistantEvent = event.assistantMessageEvent else { return }
        let deltaType = assistantEvent["type"]?.stringValue ?? "update"
        switch deltaType {
        case "text_delta", "thinking_delta":
            let delta = assistantEvent["delta"]?.stringValue ?? ""
            guard !delta.isEmpty else { return }
            if deltaType == "thinking_delta" {
                let entryID = thinkingEntryIDsBySessionID[sessionID] ?? UUID()
                thinkingEntryIDsBySessionID[sessionID] = entryID
                thinkingTextBySessionID[sessionID, default: ""] += delta
                scheduleStreamingFlush(sessionID: sessionID)
            } else {
                let entryID = assistantEntryIDsBySessionID[sessionID] ?? UUID()
                assistantEntryIDsBySessionID[sessionID] = entryID
                assistantTextBySessionID[sessionID, default: ""] += delta
                scheduleStreamingFlush(sessionID: sessionID)
            }
        case "toolcall_start":
            break
        case "error":
            store.append(.init(sessionID: sessionID, role: .error, title: "Assistant Error", text: assistantEvent.compactDescription, rawJSON: rawLine))
        default:
            break
        }
    }

    private func scheduleStreamingFlush(sessionID: UUID) {
        guard streamFlushTasksBySessionID[sessionID] == nil else { return }
        streamFlushTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.streamFlushTasksBySessionID[sessionID] = nil
                self?.flushStreamingEntries(sessionID: sessionID)
            }
        }
    }

    private func flushStreamingEntries(sessionID: UUID) {
        if let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID],
           let thinkingText = thinkingTextBySessionID[sessionID],
           !thinkingText.isEmpty {
            store.upsert(.init(
                id: thinkingEntryID,
                sessionID: sessionID,
                role: .thinking,
                title: "Thinking",
                text: thinkingText,
                rawJSON: nil
            ), before: assistantEntryIDsBySessionID[sessionID])
        }

        if let assistantEntryID = assistantEntryIDsBySessionID[sessionID],
           let assistantText = assistantTextBySessionID[sessionID] {
            store.upsert(.init(
                id: assistantEntryID,
                sessionID: sessionID,
                role: .assistant,
                title: "Assistant",
                text: assistantText,
                rawJSON: nil
            ))
        }
    }

    private func handleMessageEnd(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        guard let message = event.message else { return }
        let text = extractText(from: message)
        let role = message["role"]?.stringValue ?? "assistant"
        if role == "assistant" {
            streamFlushTasksBySessionID[sessionID]?.cancel()
            streamFlushTasksBySessionID[sessionID] = nil
            let assistantEntryID = assistantEntryIDsBySessionID[sessionID] ?? UUID()
            let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID] ?? UUID()
            let thinkingBeforeID = assistantEntryIDsBySessionID[sessionID]
            assistantEntryIDsBySessionID[sessionID] = nil
            assistantTextBySessionID[sessionID] = nil
            thinkingEntryIDsBySessionID[sessionID] = nil
            thinkingTextBySessionID[sessionID] = nil
            let visibleText = extractAssistantText(from: message)
            if !visibleText.isEmpty {
                store.upsert(.init(id: assistantEntryID, sessionID: sessionID, role: .assistant, title: "Assistant", text: visibleText, rawJSON: rawLine))
            } else {
                let thinkingText = extractAssistantThinking(from: message)
                if !thinkingText.isEmpty {
                    store.upsert(.init(id: thinkingEntryID, sessionID: sessionID, role: .thinking, title: "Thinking", text: thinkingText, rawJSON: rawLine), before: thinkingBeforeID)
                }
            }
        } else if role == "user" {
            // Pi echoes user messages back over RPC. The app already records the submitted prompt.
            return
        } else if !text.isEmpty {
            store.append(.init(sessionID: sessionID, role: .raw, title: role, text: text, rawJSON: rawLine))
        }
    }

    private func handleToolExecution(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        guard let toolCallId = event.toolCallId else { return }
        let entryID = toolEntryIDsByCallID[toolCallId] ?? UUID()
        toolEntryIDsByCallID[toolCallId] = entryID
        let toolName = event.toolName ?? "tool"
        let title = "Tool: \(toolName)"
        let text: String
        switch event.type {
        case "tool_execution_start":
            text = event.args?.compactDescription ?? "Starting…"
        case "tool_execution_update":
            text = extractText(from: event.partialResult ?? .null).isEmpty ? (event.partialResult?.compactDescription ?? "Running…") : extractText(from: event.partialResult ?? .null)
        case "tool_execution_end":
            let resultText = extractText(from: event.result ?? .null)
            text = resultText.isEmpty ? (event.result?.compactDescription ?? "Completed.") : resultText
            toolEntryIDsByCallID[toolCallId] = nil
        default:
            text = rawLine
        }
        store.upsert(.init(id: entryID, sessionID: sessionID, role: event.isError == true ? .error : .tool, title: title, text: text, rawJSON: rawLine))
    }

    private func handleCompaction(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let reason = event.reason ?? event.data?["reason"]?.stringValue ?? event.result?["reason"]?.stringValue ?? "context"
        let entryID = compactionEntryIDsBySessionID[sessionID] ?? UUID()
        compactionEntryIDsBySessionID[sessionID] = entryID

        let text: String
        if event.type == "compaction_start" {
            store.updateSession(sessionID) { $0.isCompacting = true }
            text = "Compacting conversation context (\(reason))…"
        } else if event.result != nil {
            store.updateSession(sessionID) {
                $0.isCompacting = false
                $0.contextTokens = nil
                $0.contextWindow = nil
                $0.contextPercent = nil
            }
            compactionEntryIDsBySessionID[sessionID] = nil
            let retry = event.willRetry == true ? " · retrying turn" : ""
            text = "Compaction complete\(retry)."
        } else if event.aborted == true {
            store.updateSession(sessionID) { $0.isCompacting = false }
            compactionEntryIDsBySessionID[sessionID] = nil
            text = "Compaction was aborted."
        } else {
            store.updateSession(sessionID) { $0.isCompacting = false }
            compactionEntryIDsBySessionID[sessionID] = nil
            text = event.errorMessage ?? "Compaction complete."
        }
        store.upsert(.init(id: entryID, sessionID: sessionID, role: .status, title: "Compaction", text: text, rawJSON: rawLine))
        if event.type == "compaction_end" {
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
        }
    }

    private func handleRetry(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let text = event.errorMessage ?? event.data?.compactDescription ?? rawLine
        store.append(.init(sessionID: sessionID, role: .status, title: "Retry", text: text, rawJSON: rawLine))
    }

    private func handleQueueUpdate(_ event: PiAgentRPCEvent, sessionID: UUID) {
        store.updateSession(sessionID) { record in
            record.pendingSteeringMessages = stringArray(from: event.steering) ?? []
            record.pendingFollowUpMessages = stringArray(from: event.followUp) ?? []
        }
    }

    private func handleExtensionUIRequest(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let method = event.method ?? "extension UI"
        let title = event.title ?? method

        if let requestMethod = PiAgentUIRequest.Method(rawValue: method), let requestID = event.id {
            let options: [String]
            if case let .array(values)? = event.options {
                options = values.compactMap(\.stringValue)
            } else {
                options = []
            }
            store.setUIRequest(.init(
                id: requestID,
                sessionID: sessionID,
                method: requestMethod,
                title: title,
                message: event.message?.compactDescription,
                options: options,
                placeholder: event.placeholder,
                prefill: event.prefill
            ))
            store.append(.init(sessionID: sessionID, role: .status, title: "Input Needed", text: title, rawJSON: rawLine))
            return
        }

        if method == "notify" {
            store.append(.init(sessionID: sessionID, role: .status, title: "Pi", text: event.message?.compactDescription ?? title, rawJSON: rawLine))
        } else if method != "setTitle" && method != "setStatus" && method != "setWidget" && method != "set_editor_text" {
            store.append(.init(sessionID: sessionID, role: .status, title: "Pi UI · \(method)", text: title, rawJSON: rawLine))
        }
    }

    private func transcriptEntry(from event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) -> PiAgentTranscriptEntry? {
        let type = event.type ?? "event"
        if type == "message_start" { return nil }
        if let message = event.message {
            let role = message["role"]?.stringValue ?? type
            let text = extractText(from: message)
            if text.isEmpty && type != "message_start" { return nil }
            switch role {
            case "assistant":
                return .init(sessionID: sessionID, role: .assistant, title: "Assistant", text: text.isEmpty ? type : text, rawJSON: rawLine)
            case "user":
                return nil
            case "toolResult", "bashExecution":
                return .init(sessionID: sessionID, role: .tool, title: role, text: text.isEmpty ? message.compactDescription : text, rawJSON: rawLine)
            default:
                return .init(sessionID: sessionID, role: .raw, title: role, text: text.isEmpty ? message.compactDescription : text, rawJSON: rawLine)
            }
        }

        if type.contains("tool") {
            return nil
        }
        if type.contains("error") {
            return .init(sessionID: sessionID, role: .error, title: type, text: event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine, rawJSON: rawLine)
        }
        if type.contains("start") || type.contains("end") || type.contains("status") || type.contains("idle") {
            return .init(sessionID: sessionID, role: .status, title: type, text: event.data?.compactDescription ?? type, rawJSON: rawLine)
        }
        return .init(sessionID: sessionID, role: .raw, title: type, text: event.data?.compactDescription ?? rawLine, rawJSON: rawLine)
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
                // Non-text assistant content is usually tool metadata. Do not turn it into a Pi answer.
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

    private func handleTermination(exitCode: Int32, sessionID: UUID) {
        streamFlushTasksBySessionID[sessionID]?.cancel()
        streamFlushTasksBySessionID[sessionID] = nil
        clientsBySessionID[sessionID] = nil
        let status: PiAgentRunStatus = exitCode == 0 ? .completed : .stopped
        mark(sessionID, status: status, error: nil)
        store.append(.init(sessionID: sessionID, role: .status, title: "Process Ended", text: "Pi Agent exited with code \(exitCode)."))
        onTurnFinished?(sessionID)
    }

    private func mark(_ sessionID: UUID, status: PiAgentRunStatus, error: String?) {
        store.updateSession(sessionID) { record in
            record.status = status
            record.lastError = error
            if !status.isActive {
                record.isCompacting = false
            }
        }
    }
}
