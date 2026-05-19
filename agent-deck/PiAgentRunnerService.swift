import Foundation

enum PiParentAppendPromptResolver {
    static func appendSystemPromptArguments(
        projectURL: URL,
        agentDeckAppendPrompts: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        let explicitPrompts = agentDeckAppendPrompts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !explicitPrompts.isEmpty else { return [] }

        var appendValues: [String] = []
        if let activeAppendFile = activeAppendSystemPromptURL(projectURL: projectURL, homeDirectory: homeDirectory, fileManager: fileManager) {
            appendValues.append(activeAppendFile.path)
        }
        appendValues.append(contentsOf: explicitPrompts)
        return appendValues.flatMap { ["--append-system-prompt", $0] }
    }

    static func activeAppendSystemPromptURL(
        projectURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let projectAppend = projectURL.standardizedFileURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("APPEND_SYSTEM.md")
        if fileManager.fileExists(atPath: projectAppend.path) {
            return projectAppend
        }

        let globalAppend = homeDirectory.standardizedFileURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("APPEND_SYSTEM.md")
        if fileManager.fileExists(atPath: globalAppend.path) {
            return globalAppend
        }

        return nil
    }
}

@MainActor
final class PiAgentRunnerService {
    private let store: PiAgentSessionStore
    private var clientsBySessionID: [UUID: PiRPCClient] = [:]
    private var clientRunIDsBySessionID: [UUID: UUID] = [:]
    private var stoppingClientRunIDsBySessionID: [UUID: UUID] = [:]
    private var parkingClientRunIDsBySessionID: [UUID: UUID] = [:]
    private var assistantEntryIDsBySessionID: [UUID: UUID] = [:]
    private var assistantTextBySessionID: [UUID: String] = [:]
    private var thinkingEntryIDsBySessionID: [UUID: UUID] = [:]
    private var thinkingTextBySessionID: [UUID: String] = [:]
    private var toolEntryIDsByCallID: [String: UUID] = [:]
    private var compactionEntryIDsBySessionID: [UUID: UUID] = [:]
    private struct PendingThinkingLevel {
        let requestedLevel: String
        var acknowledgedByPi = false
    }

    private var pendingCompactionInstructionsBySessionID: [UUID: String] = [:]
    private var pendingFreeformResponsesBySessionID: [UUID: String] = [:]
    private var pendingThinkingLevelsBySessionID: [UUID: PendingThinkingLevel] = [:]
    private var pendingConfigurationRestartSessionIDs: Set<UUID> = []
    private var streamFlushTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var pendingIdleTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var idleParkingTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var idleParkingTimeout: TimeInterval?
    private let idleConfirmationDelay: Duration = .milliseconds(900)
    var onTurnFinished: ((UUID) -> Void)?
    var onManagedSubagentRequest: ((UUID, PiManagedSubagentBridgeRequest, @escaping (String) -> Void) -> Void)?
    var onManagedParallelRequest: ((UUID, PiManagedParallelBridgeRequest, @escaping (String) -> Void) -> Void)?
    var onSupervisorRequestsList: ((UUID) -> String)?
    var onSupervisorRequestAnswer: ((UUID, String, String) -> String)?
    var onSessionPlanSet: ((UUID, PiSessionPlanSetBridgeRequest) -> String)?
    var onSessionPlanUpdate: ((UUID, PiSessionPlanUpdateBridgeRequest) -> String)?
    var nativeSubagentCatalogProvider: ((PiAgentSessionRecord) -> String?)?
    var parentSkillArgumentsProvider: ((URL) throws -> [String])?
    var parentPromptTemplateArgumentsProvider: ((URL) throws -> [String])?
    var parentMemoryArgumentsProvider: ((PiAgentSessionRecord, URL, String?) throws -> [String])?
    var onMemoryWrite: ((UUID, AgentMemoryWriteBridgeRequest) -> String)?
    var onMemoryMarkStale: ((UUID, AgentMemoryStaleBridgeRequest) -> String)?

    init(store: PiAgentSessionStore) {
        self.store = store
    }

    func isRunning(sessionID: UUID) -> Bool {
        clientsBySessionID[sessionID]?.isRunning == true
    }

    func configureIdleParking(timeout: TimeInterval?) {
        idleParkingTimeout = timeout
        for task in idleParkingTasksBySessionID.values {
            task.cancel()
        }
        idleParkingTasksBySessionID.removeAll()
        guard timeout != nil else { return }
        for sessionID in clientsBySessionID.keys {
            scheduleIdleParkingIfNeeded(sessionID: sessionID)
        }
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

    func resume(session: PiAgentSessionRecord, initialPrompt: String? = nil, transcriptText: String? = nil, images: [PiAgentImageAttachment] = [], pasteAttachments: [PiAgentPasteAttachment] = []) {
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        // If Pi has already created a session file, always resume it before sending a new prompt.
        // Otherwise an idle follow-up (or a model change followed by Send) starts a fresh Pi session
        // and the chat appears to lose context.
        let canResumePiSession = session.piSessionFile != nil
        start(session: session, projectURL: projectURL, initialPrompt: initialPrompt, initialTranscriptText: transcriptText, initialImages: images, initialPasteAttachments: pasteAttachments, resumeExisting: canResumePiSession)
    }

    private func restartForLaunchConfiguration(session: PiAgentSessionRecord, initialPrompt: String? = nil, transcriptText: String? = nil, images: [PiAgentImageAttachment] = [], pasteAttachments: [PiAgentPasteAttachment] = []) {
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        start(
            session: session,
            projectURL: projectURL,
            initialPrompt: initialPrompt,
            initialTranscriptText: transcriptText,
            initialImages: images,
            initialPasteAttachments: pasteAttachments,
            resumeExisting: session.piSessionFile != nil,
            recordStopTranscript: false
        )
    }

    private func applyLaunchConfigurationChange(sessionID: UUID) {
        guard clientsBySessionID[sessionID] != nil,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status.isActive {
            pendingConfigurationRestartSessionIDs.insert(sessionID)
            return
        }
        restartForLaunchConfiguration(session: session)
    }

    func send(_ text: String, mode: PiAgentInputMode, to sessionID: UUID, transcriptText displayText: String? = nil, images: [PiAgentImageAttachment] = [], pasteAttachments: [PiAgentPasteAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let message = userMessage(trimmed, images: images)
        cancelPendingIdle(for: sessionID)
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID] else {
            store.append(.init(sessionID: sessionID, role: .error, title: "Not Running", text: "Resume the session before sending a message."))
            return
        }
        let isStreaming = store.sessions.first(where: { $0.id == sessionID })?.status.isActive == true
        let effectiveMode: PiAgentInputMode = isStreaming ? .steer : mode
        if effectiveMode == .prompt,
           pendingConfigurationRestartSessionIDs.remove(sessionID) != nil,
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            restartForLaunchConfiguration(session: session, initialPrompt: text, transcriptText: displayText, images: images, pasteAttachments: pasteAttachments)
            return
        }
        let transcriptMessage = displayText.map { userMessage($0, images: images) } ?? message
        store.append(.init(sessionID: sessionID, role: .user, title: transcriptTitle(for: effectiveMode, isStreaming: isStreaming), text: transcriptText(transcriptMessage, images: images), rawJSON: transcriptAttachmentJSON(images: images, pasteAttachments: pasteAttachments)))
        switch effectiveMode {
        case .prompt:
            // Harmless when Pi is idle, but prevents dropped messages if our local
            // status lags behind Pi's authoritative streaming state.
            client.prompt(message, images: images, streamingBehavior: "steer")
        case .steer:
            client.prompt(message, images: images, streamingBehavior: "steer")
        case .followUp:
            client.prompt(message, images: images, streamingBehavior: "followUp")
        }
        mark(sessionID, status: .running, error: nil)
    }

    func syncSessionName(for sessionID: UUID, force: Bool = false) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        guard force || session.isTitleUserEdited else { return }
        let name = session.displayTitle
        if let client = clientsBySessionID[sessionID], client.isRunning {
            client.setSessionName(name)
            return
        }
        guard let sessionFile = session.piSessionFile else { return }
        appendSessionInfo(name: name, to: sessionFile)
    }

    func respondToExtensionUI(sessionID: UUID, requestID: String, value: String) {
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID], client.isRunning else {
            store.append(.init(sessionID: sessionID, role: .error, title: "Input Not Sent", text: "Pi Agent is not running, so the response could not be delivered."))
            return
        }
        client.respondToExtensionUI(id: requestID, value: value)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func respondToFreeformExtensionUI(sessionID: UUID, requestID: String, sentinel: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingFreeformResponsesBySessionID[sessionID] = trimmed
        respondToExtensionUI(sessionID: sessionID, requestID: requestID, value: sentinel)
    }

    func confirmExtensionUI(sessionID: UUID, requestID: String, confirmed: Bool) {
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID], client.isRunning else {
            store.append(.init(sessionID: sessionID, role: .error, title: "Input Not Sent", text: "Pi Agent is not running, so the response could not be delivered."))
            return
        }
        client.confirmExtensionUI(id: requestID, confirmed: confirmed)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func cancelExtensionUI(sessionID: UUID, requestID: String) {
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID], client.isRunning else {
            store.append(.init(sessionID: sessionID, role: .error, title: "Input Not Sent", text: "Pi Agent is not running, so the cancellation could not be delivered."))
            return
        }
        client.cancelExtensionUI(id: requestID)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func stop(sessionID: UUID, recordTranscript: Bool = true) {
        cancelIdleParking(for: sessionID)
        clearStreamingState(sessionID: sessionID)
        pendingConfigurationRestartSessionIDs.remove(sessionID)
        guard let client = clientsBySessionID.removeValue(forKey: sessionID) else {
            clientRunIDsBySessionID[sessionID] = nil
            stoppingClientRunIDsBySessionID[sessionID] = nil
            parkingClientRunIDsBySessionID[sessionID] = nil
            if store.sessions.first(where: { $0.id == sessionID })?.status.isActive == true {
                mark(sessionID, status: .stopped, error: nil)
                if recordTranscript {
                    store.append(.init(sessionID: sessionID, role: .status, title: "Stopped", text: "Stop requested. No active Pi Agent process was attached."))
                }
            }
            return
        }
        if let clientRunID = clientRunIDsBySessionID.removeValue(forKey: sessionID) {
            stoppingClientRunIDsBySessionID[sessionID] = clientRunID
        }
        client.stop()
        mark(sessionID, status: .stopped, error: nil)
        if recordTranscript {
            store.append(.init(sessionID: sessionID, role: .status, title: "Stopped", text: "Stop requested. Pi Agent received abort and the process is terminating."))
        }
    }

    func refreshPiControls(sessionID: UUID) {
        guard let client = clientsBySessionID[sessionID] else { return }
        resetIdleParkingDeadlineIfIdle(sessionID: sessionID)
        client.getState()
        client.getSessionStats()
    }

    func setModel(sessionID: UUID, provider: String?, modelID: String?) {
        store.updateSession(sessionID) { record in
            record.modelOverrideProvider = provider
            record.modelOverrideID = modelID
        }
        applyLaunchConfigurationChange(sessionID: sessionID)
    }

    func cycleModel(sessionID: UUID) {
        // Model cycling is resolved in AppViewModel so Agent Deck can relaunch with
        // launch-time arguments instead of Pi's default-mutating cycle_model RPC.
    }

    func setThinkingLevel(sessionID: UUID, level: String) {
        store.updateSession(sessionID) { $0.thinkingLevel = normalizedThinkingLevel(level) ?? "off" }
        applyLaunchConfigurationChange(sessionID: sessionID)
    }

    func compact(session: PiAgentSessionRecord, customInstructions: String? = nil) {
        let messageCount = store.transcript(for: session.id).filter { $0.role == .user || $0.role == .assistant }.count
        guard messageCount >= 2 else {
            store.append(.init(sessionID: session.id, role: .status, title: "Compaction", text: "Nothing to compact."))
            return
        }
        let instructions = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let client = clientsBySessionID[session.id] {
            resetIdleParkingDeadlineIfIdle(sessionID: session.id)
            client.compact(customInstructions: instructions.isEmpty ? nil : instructions)
        } else {
            pendingCompactionInstructionsBySessionID[session.id] = instructions
            resume(session: session)
        }
    }

    func cycleThinkingLevel(sessionID: UUID) {
        // Thinking cycling is resolved in AppViewModel so Agent Deck can relaunch with
        // launch-time arguments instead of Pi's default-mutating cycle_thinking_level RPC.
    }

    func stopAll(recordTranscript: Bool = true) {
        for id in Array(clientsBySessionID.keys) {
            stop(sessionID: id, recordTranscript: recordTranscript)
        }
    }

    private func start(session: PiAgentSessionRecord, projectURL: URL, initialPrompt: String?, initialTranscriptText: String? = nil, initialImages: [PiAgentImageAttachment] = [], initialPasteAttachments: [PiAgentPasteAttachment] = [], resumeExisting: Bool = false, recordStopTranscript: Bool = true) {
        stop(sessionID: session.id, recordTranscript: recordStopTranscript)
        cancelIdleParking(for: session.id)
        parkingClientRunIDsBySessionID[session.id] = nil
        stoppingClientRunIDsBySessionID[session.id] = nil
        mark(session.id, status: .starting, error: nil)
        let trimmedInitialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInitialPrompt.isEmpty || !initialImages.isEmpty {
            let message = userMessage(trimmedInitialPrompt, images: initialImages)
            let transcriptMessage = initialTranscriptText.map { userMessage($0, images: initialImages) } ?? message
            store.append(.init(sessionID: session.id, role: .user, title: "Initial Prompt", text: transcriptText(transcriptMessage, images: initialImages), rawJSON: transcriptAttachmentJSON(images: initialImages, pasteAttachments: initialPasteAttachments)))
        }

        do {
            var extraArguments: [String] = ["--no-extensions"]
            if let auditURL = try? PiNativeSubagentBridgeExtensions.systemPromptAuditExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", auditURL.path])
            }
            if let askURL = try? PiNativeSubagentBridgeExtensions.askUserExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", askURL.path])
            }
            if AppSettingsStore.shared.settings.agentMemoryEnabled,
               let memoryURL = try? PiNativeSubagentBridgeExtensions.memoryExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", memoryURL.path])
            }
            if let fastURL = try? PiNativeSubagentBridgeExtensions.openAIFastExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", fastURL.path])
            }
            for commandURL in PiInjectedCommandCatalog.extensionURLs(settings: AppSettingsStore.shared.settings) {
                extraArguments.append(contentsOf: ["--extension", commandURL.path])
            }
            if session.subagentsEnabled, let bridgeURL = try? PiNativeSubagentBridgeExtensions.parentExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", bridgeURL.path])
                if let catalog = nativeSubagentCatalogProvider?(session), !catalog.isEmpty {
                    extraArguments.append(contentsOf: PiParentAppendPromptResolver.appendSystemPromptArguments(
                        projectURL: projectURL,
                        agentDeckAppendPrompts: [catalog]
                    ))
                }
            }
            extraArguments.append("--no-skills")
            if let parentSkillArgumentsProvider {
                extraArguments.append(contentsOf: try parentSkillArgumentsProvider(projectURL))
            }
            extraArguments.append("--no-prompt-templates")
            extraArguments.append("--no-themes")
            if let parentPromptTemplateArgumentsProvider {
                extraArguments.append(contentsOf: try parentPromptTemplateArgumentsProvider(projectURL))
            }
            if let parentMemoryArgumentsProvider {
                extraArguments.append(contentsOf: try parentMemoryArgumentsProvider(session, projectURL, initialPrompt))
            }
            let sessionID = session.id
            let clientRunID = UUID()
            let launchConfiguration = launchConfiguration(for: session)
            let environment = EnvRuntimeEnvironment().environment(
                projectRoot: projectURL,
                extra: [
                    "AGENT_DECK_PARENT_SESSION_ID": session.id.uuidString,
                    "AGENT_DECK_OPENAI_FAST_CONFIG": PiNativeSubagentBridgeExtensions.openAIFastConfigURL().path
                ]
            )
            if PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment) {
                if let webURL = try? PiNativeSubagentBridgeExtensions.webAccessExtensionURL() {
                    extraArguments.append(contentsOf: ["--extension", webURL.path])
                }
            } else if WebFetchDependencyService().status().isInstalled,
                      let webURL = try? PiNativeSubagentBridgeExtensions.fallbackWebFetchExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", webURL.path])
            }
            let client = try PiRPCClient(
                cwd: projectURL,
                sessionFile: resumeExisting ? session.piSessionFile : nil,
                provider: launchConfiguration.provider,
                model: launchConfiguration.model,
                thinkingLevel: launchConfiguration.thinkingLevel,
                extraArguments: extraArguments,
                environment: environment,
                onEvent: { [weak self] events in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for event in events {
                            self.handle(rawLine: event.rawLine, event: event.event, sessionID: sessionID, clientRunID: clientRunID)
                        }
                    }
                },
                onStderr: { [weak self] lines in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for line in lines {
                            self.handle(stderr: line, sessionID: sessionID, clientRunID: clientRunID)
                        }
                    }
                },
                onTermination: { [weak self] exitCode in
                    Task { @MainActor [weak self] in self?.handleTermination(exitCode: exitCode, sessionID: sessionID, clientRunID: clientRunID) }
                }
            )
            clientsBySessionID[session.id] = client
            clientRunIDsBySessionID[session.id] = clientRunID
            store.updateSession(session.id) { record in
                record.launchCommand = client.launchCommand
                record.status = .running
            }
            client.getState()
            client.getCommands()
            let currentSession = store.sessions.first(where: { $0.id == session.id }) ?? session
            if currentSession.isTitleUserEdited || (session.title.hasPrefix("Draft ·") && !currentSession.title.hasPrefix("Draft ·")) {
                client.setSessionName(currentSession.displayTitle)
            }
            if !trimmedInitialPrompt.isEmpty || !initialImages.isEmpty {
                let message = userMessage(trimmedInitialPrompt, images: initialImages)
                cancelIdleParking(for: session.id)
                client.prompt(message, images: initialImages)
            } else if let instructions = pendingCompactionInstructionsBySessionID.removeValue(forKey: session.id) {
                cancelIdleParking(for: session.id)
                client.compact(customInstructions: instructions.isEmpty ? nil : instructions)
            } else {
                client.getMessages()
            }
        } catch {
            mark(session.id, status: .failed, error: error.localizedDescription)
            store.append(.init(sessionID: session.id, role: .error, title: "Launch Failed", text: error.localizedDescription))
        }
    }

    private func launchConfiguration(for session: PiAgentSessionRecord) -> (provider: String?, model: String?, thinkingLevel: String?) {
        let provider = firstNonEmpty(session.modelOverrideProvider, session.modelProvider)
        let model = firstNonEmpty(session.modelOverrideID, session.model)
        return (provider, model, normalizedThinkingLevel(session.thinkingLevel))
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private func resetIdleParkingDeadlineIfIdle(sessionID: UUID) {
        cancelIdleParking(for: sessionID)
        scheduleIdleParkingIfNeeded(sessionID: sessionID)
    }

    private func cancelIdleParking(for sessionID: UUID) {
        cancelPendingIdle(for: sessionID)
        idleParkingTasksBySessionID[sessionID]?.cancel()
        idleParkingTasksBySessionID[sessionID] = nil
    }

    private func cancelPendingIdle(for sessionID: UUID) {
        pendingIdleTasksBySessionID[sessionID]?.cancel()
        pendingIdleTasksBySessionID[sessionID] = nil
    }

    private func scheduleIdleConfirmation(sessionID: UUID) {
        guard pendingIdleTasksBySessionID[sessionID] == nil else { return }
        pendingIdleTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: self?.idleConfirmationDelay ?? .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.confirmIdleIfStillEligible(sessionID: sessionID)
            }
        }
    }

    private func confirmIdleIfStillEligible(sessionID: UUID) {
        pendingIdleTasksBySessionID[sessionID] = nil
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status.isActive,
              store.uiRequestsBySessionID[sessionID] == nil else { return }
        mark(sessionID, status: .idle, error: nil)
        scheduleIdleParkingIfNeeded(sessionID: sessionID)
        onTurnFinished?(sessionID)
    }

    private func scheduleIdleParkingIfNeeded(sessionID: UUID) {
        guard let timeout = idleParkingTimeout else {
            cancelIdleParking(for: sessionID)
            return
        }
        guard idleParkingTasksBySessionID[sessionID] == nil else { return }
        guard isEligibleForIdleParking(sessionID: sessionID) else { return }

        idleParkingTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.parkIdleSessionIfStillEligible(sessionID: sessionID)
            }
        }
    }

    private func parkIdleSessionIfStillEligible(sessionID: UUID) {
        idleParkingTasksBySessionID[sessionID] = nil
        guard isEligibleForIdleParking(sessionID: sessionID),
              let client = clientsBySessionID.removeValue(forKey: sessionID),
              let clientRunID = clientRunIDsBySessionID.removeValue(forKey: sessionID) else { return }
        parkingClientRunIDsBySessionID[sessionID] = clientRunID
        clearStreamingState(sessionID: sessionID)
        mark(sessionID, status: .idle, error: nil)
        client.stop()
    }

    private func isEligibleForIdleParking(sessionID: UUID) -> Bool {
        guard idleParkingTimeout != nil,
              let client = clientsBySessionID[sessionID],
              client.isRunning,
              let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status == .idle,
              session.piSessionFile?.isEmpty == false,
              store.uiRequestsBySessionID[sessionID] == nil else { return false }
        return assistantEntryIDsBySessionID[sessionID] == nil
            && assistantTextBySessionID[sessionID] == nil
            && thinkingEntryIDsBySessionID[sessionID] == nil
            && thinkingTextBySessionID[sessionID] == nil
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
            "timestamp": Self.iso8601Formatter.string(from: Date()),
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

    private static let iso8601Formatter = ISO8601DateFormatter()

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
        visibleUserText(text, imageReferences: Set(images.compactMap { $0.fileReference ?? $0.name }))
    }

    private func transcriptAttachmentJSON(images: [PiAgentImageAttachment], pasteAttachments: [PiAgentPasteAttachment] = []) -> String? {
        var payload: [String: Any] = [:]
        if !images.isEmpty,
           let imageData = try? JSONEncoder().encode(images),
           let imageObject = try? JSONSerialization.jsonObject(with: imageData) {
            payload["images"] = imageObject
        }
        if !pasteAttachments.isEmpty,
           let pasteData = try? JSONEncoder().encode(pasteAttachments),
           let pasteObject = try? JSONSerialization.jsonObject(with: pasteData) {
            payload["pastes"] = pasteObject
        }
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func visibleUserText(_ text: String, imageReferences: Set<String> = []) -> String {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var attachments: [String] = []
        var stripped = text
        for match in regex.matches(in: text, range: range).reversed() {
            let path = (text as NSString).substring(with: match.range(at: 1))
            if !imageReferences.contains(path) && !imageReferences.contains(URL(fileURLWithPath: path).lastPathComponent) {
                attachments.append(URL(fileURLWithPath: path).lastPathComponent)
            }
            if let range = Range(match.range, in: stripped) {
                stripped.removeSubrange(range)
            }
        }
        let base = stripped.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !attachments.isEmpty else { return text }
        let fileList = attachments.map { "- \($0)" }.joined(separator: "\n")
        return [base, "Attached files:\n\(fileList)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func handle(stderr: String, sessionID: UUID, clientRunID: UUID) {
        guard isCurrentClientRun(clientRunID, for: sessionID) else { return }
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

    private func isCurrentClientRun(_ clientRunID: UUID, for sessionID: UUID) -> Bool {
        clientRunIDsBySessionID[sessionID] == clientRunID
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

    private func handle(rawLine: String, event: PiAgentRPCEvent?, sessionID: UUID, clientRunID: UUID) {
        guard isCurrentClientRun(clientRunID, for: sessionID) else { return }
        guard let event else {
            store.append(.init(sessionID: sessionID, role: .raw, title: "Raw Output", text: rawLine))
            return
        }

        switch event.type {
        case "response":
            handleResponse(event, rawLine: rawLine, sessionID: sessionID)
        case "agent_start", "turn_start":
            cancelPendingIdle(for: sessionID)
            cancelIdleParking(for: sessionID)
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
            scheduleIdleConfirmation(sessionID: sessionID)
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
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
            if event.command == "set_thinking_level" || event.command == "cycle_thinking_level" {
                pendingThinkingLevelsBySessionID[sessionID] = nil
            }
            let message = event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine
            mark(sessionID, status: .failed, error: message)
            store.append(.init(sessionID: sessionID, role: .error, title: event.command ?? "RPC Error", text: message, rawJSON: rawLine))
            return
        }

        if event.command == "get_state", let data = event.data {
            applyState(data, to: sessionID)
            return
        }

        if event.command == "get_commands", let data = event.data {
            store.updateSession(sessionID) { record in
                record.commandInvocations = parseCommandInvocations(from: data)
            }
            return
        }

        if event.command == "set_model" || event.command == "cycle_model", let data = event.data {
            store.updateSession(sessionID) { record in
                if let modelObject = data["model"] ?? (data["id"] == nil ? nil : data) {
                    updateModelFields(on: &record, from: modelObject, useAsOverride: true)
                }
                if let thinkingLevel = data["thinkingLevel"]?.stringValue {
                    pendingThinkingLevelsBySessionID[sessionID] = nil
                    record.thinkingLevel = thinkingLevel
                }
            }
            clientsBySessionID[sessionID]?.getState()
            return
        }

        if event.command == "set_thinking_level" || event.command == "cycle_thinking_level" {
            store.updateSession(sessionID) { record in
                if let data = event.data,
                   let thinkingLevel = data["level"]?.stringValue ?? data["thinkingLevel"]?.stringValue {
                    pendingThinkingLevelsBySessionID[sessionID] = nil
                    record.thinkingLevel = thinkingLevel
                } else if event.command == "set_thinking_level",
                          var pending = pendingThinkingLevelsBySessionID[sessionID] {
                    pending.acknowledgedByPi = true
                    pendingThinkingLevelsBySessionID[sessionID] = pending
                }
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
                $0.contextBreakdown = []
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
                    record.contextBreakdown = Self.parseContextBreakdown(from: contextUsage)
                } else {
                    record.contextTokens = nil
                    record.contextWindow = nil
                    record.contextPercent = nil
                    record.contextBreakdown = []
                }
            }
        }
    }

    private static func parseContextBreakdown(from contextUsage: JSONValue) -> [PiAgentContextBreakdownItem] {
        let contextWindow = contextUsage["contextWindow"]?.numberValue
        let candidates = [
            contextUsage["breakdown"],
            contextUsage["categories"],
            contextUsage["segments"],
            contextUsage["details"]
        ].compactMap { $0 }

        for candidate in candidates {
            let parsed = parseContextBreakdownCandidate(candidate, contextWindow: contextWindow)
            if parsed.isEmpty == false {
                return parsed
            }
        }
        return []
    }

    private static func parseContextBreakdownCandidate(_ value: JSONValue, contextWindow: Double?) -> [PiAgentContextBreakdownItem] {
        switch value {
        case let .array(items):
            return items.compactMap { parseContextBreakdownItem($0, fallbackKey: nil, contextWindow: contextWindow) }
        case let .object(object):
            return contextBreakdownKeys(Array(object.keys)).compactMap { key in
                parseContextBreakdownItem(object[key], fallbackKey: key, contextWindow: contextWindow)
            }
        default:
            return []
        }
    }

    private static func parseContextBreakdownItem(_ value: JSONValue?, fallbackKey: String?, contextWindow: Double?) -> PiAgentContextBreakdownItem? {
        guard let value else { return nil }
        guard case let .object(object) = value else {
            if let tokens = value.numberValue.map(Int.init), let fallbackKey {
                let percent = contextWindow.flatMap { $0 > 0 ? (Double(tokens) / $0) * 100 : nil }
                return .init(key: fallbackKey, title: contextBreakdownTitle(for: fallbackKey), tokens: tokens, percent: percent)
            }
            return nil
        }

        let key = object["key"]?.stringValue
            ?? object["id"]?.stringValue
            ?? object["name"]?.stringValue
            ?? object["type"]?.stringValue
            ?? fallbackKey
            ?? UUID().uuidString
        let title = object["title"]?.stringValue
            ?? object["label"]?.stringValue
            ?? contextBreakdownTitle(for: key)
        let tokens = firstNumber(in: object, keys: ["tokens", "tokenCount", "count", "usedTokens"]).map(Int.init)
        let reportedPercent = firstNumber(in: object, keys: ["percent", "percentage", "pct", "ratio"]).map { value in
            value <= 1 ? value * 100 : value
        }
        let percent = reportedPercent ?? tokens.flatMap { tokens in
            contextWindow.flatMap { $0 > 0 ? (Double(tokens) / $0) * 100 : nil }
        }
        let detail = object["detail"]?.stringValue ?? object["description"]?.stringValue

        if tokens == nil, percent == nil, detail == nil {
            return nil
        }
        return .init(key: key, title: title, tokens: tokens, percent: percent, detail: detail)
    }

    private static func firstNumber(in object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key]?.numberValue {
                return value
            }
        }
        return nil
    }

    private static func contextBreakdownKeys(_ keys: [String]) -> [String] {
        let order = [
            "systemPrompt", "system_prompt",
            "systemTools", "system_tools",
            "messages",
            "toolCalls", "tool_calls",
            "toolResults", "tool_results",
            "subagentResults", "subagent_results",
            "freeSpace", "free_space",
            "autocompactBuffer", "autocompact_buffer",
            "slashCommandTool", "slash_command_tool"
        ]
        return keys.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs) ?? Int.max
            if lhsIndex == rhsIndex {
                return lhs < rhs
            }
            return lhsIndex < rhsIndex
        }
    }

    private static func contextBreakdownTitle(for key: String) -> String {
        let knownTitles = [
            "systemPrompt": "System prompt",
            "system_prompt": "System prompt",
            "systemTools": "System tools",
            "system_tools": "System tools",
            "messages": "Messages",
            "toolCalls": "Tool calls",
            "tool_calls": "Tool calls",
            "toolResults": "Tool results",
            "tool_results": "Tool results",
            "subagentResults": "Subagent results",
            "subagent_results": "Subagent results",
            "freeSpace": "Free space",
            "free_space": "Free space",
            "autocompactBuffer": "Autocompact buffer",
            "autocompact_buffer": "Autocompact buffer",
            "slashCommandTool": "SlashCommand Tool",
            "slash_command_tool": "SlashCommand Tool"
        ]
        if let title = knownTitles[key] {
            return title
        }

        let spaced = key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        guard let first = spaced.first else { return "Context" }
        return String(first).uppercased() + String(spaced.dropFirst())
    }

    private func normalizedThinkingLevel(_ level: String?) -> String? {
        guard let level = level?.trimmingCharacters(in: .whitespacesAndNewlines), !level.isEmpty else { return nil }
        return level == "none" ? "off" : level
    }

    private func applyState(_ data: JSONValue, to sessionID: UUID) {
        let reportedThinkingLevel = data["thinkingLevel"]?.stringValue
        let pendingThinkingLevel = pendingThinkingLevelsBySessionID[sessionID]
        var shouldScheduleIdleParking = false
        store.updateSession(sessionID) { record in
            record.piSessionFile = data["sessionFile"]?.stringValue ?? record.piSessionFile
            record.piSessionId = data["sessionId"]?.stringValue ?? record.piSessionId
            if let modelObject = data["model"] {
                updateModelFields(on: &record, from: modelObject, useAsOverride: false)
            }
            if let pendingThinkingLevel {
                // Some Pi builds acknowledge set_thinking_level without echoing the new level,
                // then report the launch/default level from get_state while the requested
                // level is already what the turn will use. Keep the user's explicit choice
                // until Pi reports that same level or another explicit control event wins.
                record.thinkingLevel = pendingThinkingLevel.requestedLevel
            } else {
                record.thinkingLevel = reportedThinkingLevel ?? record.thinkingLevel
            }
            if let streaming = data["isStreaming"]?.compactDescription, streaming == "true" {
                cancelPendingIdle(for: sessionID)
                cancelIdleParking(for: sessionID)
                record.status = .running
            } else if record.status.isActive {
                scheduleIdleConfirmation(sessionID: sessionID)
            } else if record.status == .idle {
                shouldScheduleIdleParking = true
            }
        }
        if let pendingThinkingLevel,
           pendingThinkingLevel.acknowledgedByPi,
           normalizedThinkingLevel(reportedThinkingLevel) == normalizedThinkingLevel(pendingThinkingLevel.requestedLevel) {
            pendingThinkingLevelsBySessionID[sessionID] = nil
        }
        if shouldScheduleIdleParking {
            scheduleIdleParkingIfNeeded(sessionID: sessionID)
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

    private func parseCommandInvocations(from value: JSONValue) -> [String] {
        let commands: [JSONValue]
        if case let .array(items) = value {
            commands = items
        } else if case let .array(items)? = value["commands"] {
            commands = items
        } else {
            commands = []
        }

        return Array(Set(commands.compactMap { item -> String? in
            let raw = item["name"]?.stringValue ?? item["invocation"]?.stringValue ?? item.stringValue
            guard let raw, !raw.isEmpty else { return nil }
            return raw.hasPrefix("/") ? raw : "/\(raw)"
        })).sorted()
    }

    private func stringArray(from value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
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
        let delay = streamingFlushDelay(for: sessionID)
        streamFlushTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.streamFlushTasksBySessionID[sessionID] = nil
                self?.flushStreamingEntries(sessionID: sessionID)
            }
        }
    }

    private func streamingFlushDelay(for sessionID: UUID) -> UInt64 {
        // Cadence governs how big each per-flush scroll step is. Bigger delays = more
        // text per flush = bigger pixel jumps when pinned-to-bottom scrollToBottom snaps
        // the origin. Previously these were 60/80/120 ms to keep CPU low — each flush
        // re-ran the SwiftUI MarkdownTextView body and triggered a fresh per-block view
        // tree (slow). With markdown measurement now going through TextKit and streaming
        // updates being in-place NSTextStorage replacements (Step 4), each flush is
        // ~microseconds of layout work; we can afford much faster cadence and the user
        // perceives streaming as smooth scroll instead of discrete steps.
        let characterCount = (assistantTextBySessionID[sessionID]?.count ?? 0) + (thinkingTextBySessionID[sessionID]?.count ?? 0)
        switch characterCount {
        case 0..<1_000:
            return 33_000_000   // ~30 fps
        case 1_000..<4_000:
            return 45_000_000   // ~22 fps
        default:
            return 60_000_000   // ~17 fps for very long messages
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
            ), before: assistantEntryIDsBySessionID[sessionID], persist: false)
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
            ), persist: false)
        }
    }

    private func clearStreamingState(sessionID: UUID) {
        idleParkingTasksBySessionID[sessionID]?.cancel()
        idleParkingTasksBySessionID[sessionID] = nil
        streamFlushTasksBySessionID[sessionID]?.cancel()
        streamFlushTasksBySessionID[sessionID] = nil
        assistantEntryIDsBySessionID[sessionID] = nil
        assistantTextBySessionID[sessionID] = nil
        thinkingEntryIDsBySessionID[sessionID] = nil
        thinkingTextBySessionID[sessionID] = nil
        pendingFreeformResponsesBySessionID[sessionID] = nil
        pendingThinkingLevelsBySessionID[sessionID] = nil
        let keyPrefix = "\(sessionID.uuidString):"
        toolEntryIDsByCallID = toolEntryIDsByCallID.filter { !$0.key.hasPrefix(keyPrefix) }
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
                store.upsert(.init(id: assistantEntryID, sessionID: sessionID, role: .assistant, title: "Assistant", text: visibleText, rawJSON: nil))
            } else {
                let thinkingText = extractAssistantThinking(from: message)
                if !thinkingText.isEmpty {
                    store.upsert(.init(id: thinkingEntryID, sessionID: sessionID, role: .thinking, title: "Thinking", text: thinkingText, rawJSON: nil), before: thinkingBeforeID)
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
        let toolKey = "\(sessionID.uuidString):\(toolCallId)"
        let entryID = toolEntryIDsByCallID[toolKey] ?? UUID()
        toolEntryIDsByCallID[toolKey] = entryID
        let toolName = event.toolName ?? "tool"
        let title = "Tool: \(toolName)"
        let text: String
        switch event.type {
        case "tool_execution_start":
            // Close out any in-flight thinking entry before the tool card materializes so
            // the renderer keeps pre-tool reasoning visually above the tool, and any new
            // post-tool reasoning opens a fresh thinking entry with a later timestamp.
            finalizeStreamingThinking(sessionID: sessionID)
            text = event.args?.compactDescription ?? "Starting…"
        case "tool_execution_update":
            text = extractText(from: event.partialResult ?? .null).isEmpty ? (event.partialResult?.compactDescription ?? "Running…") : extractText(from: event.partialResult ?? .null)
        case "tool_execution_end":
            // Also close out on tool end — by the time the next thinking_delta arrives,
            // we want a brand-new thinking entry whose timestamp is after this tool's.
            finalizeStreamingThinking(sessionID: sessionID)
            let resultText = extractText(from: event.result ?? .null)
            text = resultText.isEmpty ? (event.result?.compactDescription ?? "Completed.") : resultText
            toolEntryIDsByCallID[toolKey] = nil
        default:
            text = rawLine
        }
        store.upsert(.init(id: entryID, sessionID: sessionID, role: event.isError == true ? .error : .tool, title: title, text: text, rawJSON: rawLine))
    }

    /// Flushes any pending thinking text to the store and clears the in-flight thinking
    /// entry id/buffer so subsequent thinking_delta events open a new entry. Called at
    /// tool boundaries inside a single assistant message so each reasoning pass is its
    /// own transcript entry with its own timestamp.
    private func finalizeStreamingThinking(sessionID: UUID) {
        guard let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID],
              let thinkingText = thinkingTextBySessionID[sessionID],
              !thinkingText.isEmpty else {
            thinkingEntryIDsBySessionID[sessionID] = nil
            thinkingTextBySessionID[sessionID] = nil
            return
        }
        store.upsert(.init(
            id: thinkingEntryID,
            sessionID: sessionID,
            role: .thinking,
            title: "Thinking",
            text: thinkingText,
            rawJSON: nil
        ), before: assistantEntryIDsBySessionID[sessionID], persist: false)
        thinkingEntryIDsBySessionID[sessionID] = nil
        thinkingTextBySessionID[sessionID] = nil
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
                $0.contextBreakdown = []
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
        let method = nonEmptyBridgeString(event.method) ?? extensionUIString("method", from: event) ?? "extension UI"
        let title = extensionUITitle(from: event) ?? method

        if let bridgeName = agentDeckBridgeName(from: event) {
            guard let requestID = extensionUIRequestID(from: event) else {
                store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Bridge request \(bridgeName) did not include a request id.", rawJSON: rawLine))
                return
            }

            switch bridgeName {
            case "managed_subagent":
                handleManagedSubagentBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "managed_parallel":
                handleManagedParallelBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "list_supervisor_requests":
                let result = onSupervisorRequestsList?(sessionID) ?? "[]"
                clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
            case "answer_supervisor_request":
                handleAnswerSupervisorBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "set_session_plan":
                handleSetSessionPlanBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "update_session_plan":
                handleUpdateSessionPlanBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "system_prompt_audit":
                handleSystemPromptAuditBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "ask_user":
                handleNativeAskUserBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "memory_write":
                handleMemoryWriteBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "memory_mark_stale":
                handleMemoryMarkStaleBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            default:
                clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) does not support bridge request \(bridgeName).")
                store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Unsupported bridge request \(bridgeName).", rawJSON: rawLine))
            }
            return
        }

        if let requestMethod = PiAgentUIRequest.Method(rawValue: method), let requestID = event.id {
            if requestMethod == .input, let pendingFreeform = pendingFreeformResponsesBySessionID.removeValue(forKey: sessionID) {
                clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: pendingFreeform)
                store.append(.init(sessionID: sessionID, role: .status, title: "Input Sent", text: "Custom response sent.", rawJSON: rawLine))
                return
            }

            let parsedRequest = parsedUIRequest(
                id: requestID,
                sessionID: sessionID,
                method: requestMethod,
                title: title,
                message: event.message?.compactDescription,
                options: event.options,
                placeholder: event.placeholder,
                prefill: event.prefill
            )
            store.setUIRequest(parsedRequest)
            store.append(.init(sessionID: sessionID, role: .status, title: "Input Needed", text: title, rawJSON: rawLine))
            return
        }

        if method == "notify" {
            store.append(.init(sessionID: sessionID, role: .status, title: "Pi", text: event.message?.compactDescription ?? title, rawJSON: rawLine))
        } else if method != "setTitle" && method != "setStatus" && method != "setWidget" && method != "set_editor_text" {
            store.append(.init(sessionID: sessionID, role: .status, title: "Pi UI · \(method)", text: title, rawJSON: rawLine))
        }
    }

    private func handleMemoryMarkStaleBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryStaleBridgeRequest.self, from: data) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the stale memory request.")
            store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse stale memory request.", rawJSON: rawLine))
            return
        }
        let result = onMemoryMarkStale?(sessionID, request) ?? "\(AppBrand.displayName) memory is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    private func handleMemoryWriteBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryWriteBridgeRequest.self, from: data) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the memory write request.")
            store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse memory write request.", rawJSON: rawLine))
            return
        }
        let result = onMemoryWrite?(sessionID, request) ?? "\(AppBrand.displayName) memory is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    private func handleManagedSubagentBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiManagedSubagentBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the managed_subagent request.")
            return
        }
        guard let onManagedSubagentRequest else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) native subagent bridge is not available.")
            return
        }
        onManagedSubagentRequest(sessionID, request) { [weak self] result in
            Task { @MainActor in
                self?.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
            }
        }
    }

    private func handleManagedParallelBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiManagedParallelBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the managed_parallel request.")
            return
        }
        guard let onManagedParallelRequest else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) native parallel bridge is not available.")
            return
        }
        onManagedParallelRequest(sessionID, request) { [weak self] result in
            Task { @MainActor in
                self?.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
            }
        }
    }

    private func handleAnswerSupervisorBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSupervisorAnswerBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the supervisor response request.")
            return
        }
        let result = onSupervisorRequestAnswer?(sessionID, request.requestID, request.response) ?? "\(AppBrand.displayName) supervisor routing is not available."
        store.append(.init(sessionID: sessionID, role: .status, title: "Supervisor Response Routed", text: request.requestID, rawJSON: rawLine))
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    private func handleSetSessionPlanBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSessionPlanSetBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the session plan request.")
            return
        }
        let result = onSessionPlanSet?(sessionID, request) ?? "\(AppBrand.displayName) session plan routing is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    private func handleUpdateSessionPlanBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSessionPlanUpdateBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the session plan update.")
            return
        }
        let result = onSessionPlanUpdate?(sessionID, request) ?? "\(AppBrand.displayName) session plan routing is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    private func handleSystemPromptAuditBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSystemPromptAuditBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the system prompt audit request.")
            return
        }
        let now = Date()
        store.updateSession(sessionID, bumpUpdatedAt: false) { record in
            record.finalSystemPrompt = request.systemPrompt
            record.finalSystemPromptCapturedAt = now
        }
        store.append(.init(sessionID: sessionID, role: .status, title: "System Prompt Captured", text: "Captured \(request.systemPrompt.count) characters from Pi runtime.", rawJSON: rawLine))
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "System prompt captured.")
    }

    private func handleNativeAskUserBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiNativeAskBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: #"{"cancelled":true,"error":"\#(AppBrand.displayName) could not parse the ask_user request."}"#)
            return
        }

        let options = request.normalizedOptions
        let method: PiAgentUIRequest.Method = options.isEmpty
            ? .input
            : (request.allowMultiple == true ? .multiSelect : .select)
        var descriptions: [String: String] = [:]
        for option in options {
            if let description = option.description {
                descriptions[option.title] = description
            }
        }
        store.setUIRequest(.init(
            id: requestID,
            sessionID: sessionID,
            method: method,
            title: request.question,
            message: request.context,
            options: options.map(\.title),
            optionDescriptions: descriptions,
            placeholder: options.isEmpty ? "Type your answer..." : nil,
            prefill: nil,
            allowsFreeform: request.allowFreeform ?? true,
            allowsComment: !options.isEmpty,
            responseFormat: .nativeAsk
        ))
        store.append(.init(sessionID: sessionID, role: .status, title: "Input Needed", text: request.question, rawJSON: rawLine))
    }

    private func bridgePayload(from event: PiAgentRPCEvent) -> String? {
        if let prefill = nonEmptyBridgeString(event.prefill) { return prefill }
        if let prefill = extensionUIString("prefill", from: event) { return prefill }
        if let message = event.message?.stringValue, !message.isEmpty { return message }
        if let message = extensionUIString("message", from: event) { return message }
        return event.message?.compactDescription
    }

    private func agentDeckBridgeName(from event: PiAgentRPCEvent) -> String? {
        guard let title = extensionUITitle(from: event) else { return nil }
        let prefix = "AGENT_DECK_BRIDGE "
        guard title.hasPrefix(prefix) else { return nil }
        let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func extensionUITitle(from event: PiAgentRPCEvent) -> String? {
        if let title = nonEmptyBridgeString(event.title) { return title }
        if let title = extensionUIString("title", from: event) { return title }
        if let method = nonEmptyBridgeString(event.method), method.hasPrefix("AGENT_DECK_BRIDGE ") { return method }
        return nil
    }

    private func extensionUIRequestID(from event: PiAgentRPCEvent) -> String? {
        nonEmptyBridgeString(event.id) ?? extensionUIString("id", from: event)
    }

    private func extensionUIString(_ key: String, from event: PiAgentRPCEvent) -> String? {
        nonEmptyBridgeString(event.data?[key]?.stringValue)
            ?? nonEmptyBridgeString(event.message?[key]?.stringValue)
            ?? nonEmptyBridgeString(event.result?[key]?.stringValue)
    }

    private func nonEmptyBridgeString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func parsedUIRequest(
        id: String,
        sessionID: UUID,
        method: PiAgentUIRequest.Method,
        title: String,
        message: String?,
        options: JSONValue?,
        placeholder: String?,
        prefill: String?
    ) -> PiAgentUIRequest {
        if method == .input,
           placeholder == "Type your selection(s)...",
           let parsed = parseMultiSelectInputTitle(title) {
            return .init(
                id: id,
                sessionID: sessionID,
                method: .multiSelect,
                title: parsed.question,
                message: parsed.context,
                options: parsed.options,
                optionDescriptions: [:],
                placeholder: placeholder,
                prefill: prefill,
                allowsFreeform: true,
                allowsComment: false,
                responseFormat: .plain
            )
        }

        let optionTitles: [String]
        if case let .array(values)? = options {
            optionTitles = values.compactMap(\.stringValue)
        } else {
            optionTitles = []
        }
        return .init(
            id: id,
            sessionID: sessionID,
            method: method,
            title: title,
            message: message,
            options: optionTitles,
            optionDescriptions: [:],
            placeholder: placeholder,
            prefill: prefill,
            allowsFreeform: true,
            allowsComment: false,
            responseFormat: .plain
        )
    }

    private func parseMultiSelectInputTitle(_ title: String) -> (question: String, context: String?, options: [String])? {
        let marker = "\n\nOptions (select one or more):\n"
        guard let markerRange = title.range(of: marker) else { return nil }
        let prompt = String(title[..<markerRange.lowerBound])
        let optionLines = title[markerRange.upperBound...].split(whereSeparator: \.isNewline)
        let options = optionLines.compactMap { line -> String? in
            guard let separator = line.firstIndex(of: ".") else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard !options.isEmpty else { return nil }

        let contextMarker = "\n\nContext:\n"
        if let contextRange = prompt.range(of: contextMarker) {
            let question = String(prompt[..<contextRange.lowerBound])
            let context = String(prompt[contextRange.upperBound...])
            return (question, context, options)
        }
        return (prompt, nil, options)
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
                return .init(sessionID: sessionID, role: .assistant, title: "Assistant", text: text.isEmpty ? type : text, rawJSON: nil)
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

    private func handleTermination(exitCode: Int32, sessionID: UUID, clientRunID: UUID) {
        if parkingClientRunIDsBySessionID[sessionID] == clientRunID {
            parkingClientRunIDsBySessionID[sessionID] = nil
            clearStreamingState(sessionID: sessionID)
            if clientsBySessionID[sessionID] == nil {
                mark(sessionID, status: .idle, error: nil)
            }
            return
        }

        if stoppingClientRunIDsBySessionID[sessionID] == clientRunID {
            stoppingClientRunIDsBySessionID[sessionID] = nil
            clearStreamingState(sessionID: sessionID)
            if clientRunIDsBySessionID[sessionID] == clientRunID {
                clientRunIDsBySessionID[sessionID] = nil
                clientsBySessionID[sessionID] = nil
                mark(sessionID, status: .stopped, error: nil)
            }
            return
        }

        guard clientRunIDsBySessionID[sessionID] == clientRunID else { return }
        clearStreamingState(sessionID: sessionID)
        clientRunIDsBySessionID[sessionID] = nil
        clientsBySessionID[sessionID] = nil
        let status: PiAgentRunStatus = exitCode == 0 ? .completed : .stopped
        mark(sessionID, status: status, error: nil)
        store.append(.init(sessionID: sessionID, role: .status, title: "Process Ended", text: "Pi Agent exited with code \(exitCode)."))
        onTurnFinished?(sessionID)
    }

    private func mark(_ sessionID: UUID, status: PiAgentRunStatus, error: String?) {
        cancelPendingIdle(for: sessionID)
        store.updateSession(sessionID) { record in
            record.status = status
            record.lastError = error
            if !status.isActive {
                record.isCompacting = false
            }
        }
    }
}
