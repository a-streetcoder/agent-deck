import Foundation
import os

/// Temporary diagnostic logger for the inbound RPC → transcript-entry path.
/// Off unless launched with `AGENTDECK_RPC_LOG=1`. Writes one line per event to
/// `/tmp/agentdeck-rpc.log` (truncated each launch). Used to capture exactly what
/// a provider emits at end-of-turn (e.g. duplicate end-events) — remove once the
/// duplicate/empty assistant-entry questions are settled.
@MainActor
enum RPCDebugLog {
#if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["AGENTDECK_RPC_LOG"] != nil
    private static var handle: FileHandle? = {
        guard enabled else { return nil }
        FileManager.default.createFile(atPath: "/tmp/agentdeck-rpc.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/agentdeck-rpc.log")
    }()

    static func log(_ line: String) {
        guard enabled else { return }
        let out = line + "\n"
        FileHandle.standardError.write(Data("[rpc] \(out)".utf8))
        handle?.write(Data(out.utf8))
    }
#else
    static func log(_ line: String) {}
#endif
}

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
    nonisolated static let logger = Logger(subsystem: "works.earendil.pi-deck", category: "PiRPC")
    /// Number of inbound events still to log after a compaction completes, per session.
    /// Lets us prove whether Pi continues a turn after compaction without logging message content.
    var postCompactionLogCountBySessionID: [UUID: Int] = [:]
    let store: PiAgentSessionStore
    var clientsBySessionID: [UUID: PiRPCClient] = [:]
    var clientRunIDsBySessionID: [UUID: UUID] = [:]
    /// Identifies the only startup continuation allowed to register a client for
    /// a session. Replaced by a newer resume and invalidated by stop().
    var launchGenerationsBySessionID: [UUID: UUID] = [:]
    /// Bounds all launch-time preparation before PiRPCClient is registered. Providers
    /// can involve MCP discovery or memory lookup; if one wedges, fail the launch
    /// instead of leaving the session permanently stuck in Starting.
    var launchWatchdogTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    let launchSetupTimeout: Duration
    /// User input submitted while launch-time setup (such as MCP discovery) is
    /// still awaiting a client. It is recorded immediately, then delivered in
    /// FIFO order after the registered client's initial startup action.
    struct PendingStartupInput {
        let message: String
        let images: [PiAgentImageAttachment]
    }
    var pendingStartupInputsBySessionID: [UUID: [PendingStartupInput]] = [:]
    var afterFinishHookRunIDs: Set<UUID> = []
    var stoppingClientRunIDsBySessionID: [UUID: UUID] = [:]
    var parkingClientRunIDsBySessionID: [UUID: UUID] = [:]
    var assistantEntryIDsBySessionID: [UUID: UUID] = [:]
    var assistantTextBySessionID: [UUID: String] = [:]
    var thinkingEntryIDsBySessionID: [UUID: UUID] = [:]
    var thinkingTextBySessionID: [UUID: String] = [:]
    var toolEntryIDsByCallID: [String: UUID] = [:]
    /// A tool call's arguments, captured from `tool_execution_start` and kept until
    /// the call ends. The update/end events drop the top-level `args`, but transcript
    /// cards (notably the MCP card, which needs the `server/tool` address that only
    /// lives in `args`) read it off the entry — so we re-attach it to every later
    /// event's rawJSON for this call.
    var toolStartArgsByCallID: [String: JSONValue] = [:]
    var compactionEntryIDsBySessionID: [UUID: UUID] = [:]
    struct PendingThinkingLevel {
        let requestedLevel: String
        var acknowledgedByPi = false
    }

    var pendingCompactionInstructionsBySessionID: [UUID: String] = [:]
    var pendingFreeformResponsesBySessionID: [UUID: String] = [:]
    /// Sessions whose transcript we've already reconciled against Pi's session file
    /// on open this launch — keeps the on-view disk read to once per session.
    var rehydratedFromDiskSessionIDs: Set<UUID> = []
    /// Authoritative Pi messages seen via `get_messages`, live final messages, or
    /// the session JSONL. Category costs are derived only from these messages and
    /// displayed only after they reconcile with `get_session_stats` total cost.
    var piMessagesBySessionID: [UUID: [JSONValue]] = [:]
    var pendingThinkingLevelsBySessionID: [UUID: PendingThinkingLevel] = [:]
    /// Re-run: everything needed to resend the forked message exactly as it was
    /// originally sent — the display text and the recorded attachments (images
    /// must re-attach; pastes/issue content is already inline in Pi's recorded
    /// text but is needed for faithful transcript chips).
    struct RerunDelivery {
        var transcriptText: String?
        var images: [PiAgentImageAttachment] = []
        var pasteAttachments: [PiAgentPasteAttachment] = []
    }

    struct ForkProgress {
        let userMessageText: String
        let userMessageIndex: Int
        /// The Agent Deck transcript entry being forked at. Re-run truncates the
        /// local transcript here; a normal fork cuts its recap snapshot here so
        /// the fork-origin card shows exactly the inherited history.
        let sourceEntryID: UUID?
        /// Non-nil = re-run: once the fork materializes, send the forked user
        /// message immediately instead of parking it in the composer.
        let rerun: RerunDelivery?
        var phase: Phase
        var getForkMessagesSent: Bool
        enum Phase {
            case fetchingMessages
            case forking
            case fetchingState(forkText: String)
        }
    }
    var forkProgressBySessionID: [UUID: ForkProgress] = [:]
    var pendingConfigurationRestartSessionIDs: Set<UUID> = []
    /// Human-readable summary of the config change driving the next relaunch
    /// (e.g. "thinking level to off"). Set by setModel/setThinkingLevel, consumed
    /// inside start() to seed `.applyingConfigurationChange` on the processing bar
    /// so the user sees why Pi is briefly active.
    var pendingConfigurationChangeSummariesBySessionID: [UUID: String] = [:]
    var streamFlushTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    var pendingIdleTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// Sessions for which Pi has emitted `agent_start` (or at least `turn_start`) but
    /// not the authoritative `agent_end`. `isStreaming` can be false between turns,
    /// after tool use, compaction, or retries, so it is not by itself a turn-finished signal.
    var activeAgentRunSessionIDs: Set<UUID> = []
    var idleParkingTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    var idleParkingTimeout: TimeInterval?
    let idleConfirmationDelay: Duration = .milliseconds(900)
    var onTurnFinished: ((UUID) -> Void)?
    /// Called only when a parent Pi process ends outside an intentional stop,
    /// idle park, or launch-configuration relaunch.
    var onSessionProcessTerminated: ((UUID) -> Void)?
    var onSessionLaunched: ((UUID) -> Void)?
    var onManagedSubagentRequest: ((UUID, PiManagedSubagentBridgeRequest, @escaping (String) -> Void) -> Void)?
    var onManagedParallelRequest: ((UUID, PiManagedParallelBridgeRequest, @escaping (String) -> Void) -> Void)?
    var onSupervisorRequestsList: ((UUID) -> String)?
    var onSupervisorRequestAnswer: ((UUID, String, String) -> String)?
    var onSessionPlanSet: ((UUID, PiSessionPlanSetBridgeRequest) -> String)?
    var onSessionPlanUpdate: ((UUID, PiSessionPlanUpdateBridgeRequest) -> String)?
    var nativeSubagentCatalogProvider: ((PiAgentSessionRecord) -> String?)?
    /// Returns the compact MCP tool catalog to inject for this session, scoped to its
    /// assigned servers. Nil/empty means MCP is off for the session: no bridge, no
    /// system-prompt block (same gating as the Deck-agents catalog). Async so the
    /// provider can discover a non-active project's servers on demand instead of
    /// relying solely on the active-project snapshot.
    var mcpCatalogProvider: ((PiAgentSessionRecord) async -> String?)?
    var onMCPBridgeRequest: ((UUID, PiMCPBridgeRequest, @escaping (String) -> Void) -> Void)?
    var parentSkillArgumentsProvider: ((URL) throws -> [String])?
    var agentDeckBuilderSkillArgumentsProvider: (() throws -> [String])?
    var parentPromptTemplateArgumentsProvider: ((URL) throws -> [String])?
    /// Returns the Agent Deck memory append *prompt texts* (policy + recall) for a
    /// parent session — not flag pairs. APPEND_SYSTEM.md preservation is applied once
    /// by the launch flow, not per provider, so memory must not re-add it here.
    var parentMemoryAppendPromptsProvider: ((PiAgentSessionRecord, String?) async throws -> [String])?
    /// Resolves a session's bound agent against the current scan snapshot for
    /// `kind == .agent` sessions. Returning `nil` causes the launch to fail
    /// with an "Agent Unavailable" transcript error.
    var boundAgentProvider: ((PiAgentSessionRecord) -> EffectiveAgentRecord?)?
    /// Returns the `--skill <name=path>` argument list for an agent-bound
    /// session. Wired by `AppViewModel` to
    /// `PiSkillLaunchResolver.childSkillArguments(agent:snapshot:)`.
    var boundAgentSkillArgumentsProvider: ((EffectiveAgentRecord) throws -> [String])?
    var onMemoryWrite: ((UUID, AgentMemoryWriteBridgeRequest) async -> String)?
    var onMemoryMarkStale: ((UUID, AgentMemoryStaleBridgeRequest) async -> String)?
    var onMemorySearch: ((UUID, AgentMemorySearchBridgeRequest) async -> String)?

    init(store: PiAgentSessionStore, launchSetupTimeout: Duration = .seconds(45)) {
        self.store = store
        self.launchSetupTimeout = launchSetupTimeout
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
            title: title.isEmpty ? LanguageStore.shared.t("vm.newAgentSession") : String(title.prefix(80)),
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        let prompt = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [weak self] in
            await self?.start(session: session, projectURL: project.url, initialPrompt: prompt)
        }
    }



    /// Create and launch a new 1:1 chat session bound to a specific agent.
    /// Pi is spawned with the agent's system prompt, tool allowlist, and
    /// agent-defined extensions on top of the usual user-extension stack.
    /// There is no `managed_subagent` bridge above this session — the user is
    /// the supervisor, and the agent cannot delegate to other agents.
    func startAgentSession(agent: EffectiveAgentRecord, project: DiscoveredProject, initialInstruction: String?) {
        guard agent.resolved.disabled != true else { return }
        let session = store.createSession(
            kind: .agent,
            title: "Chat · \(agent.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner,
            agentName: agent.name
        )
        let trimmedPrompt = initialInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor [weak self] in
            await self?.start(
                session: session,
                projectURL: project.url,
                initialPrompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt
            )
        }
    }

    func resume(
        session: PiAgentSessionRecord,
        initialPrompt: String? = nil,
        transcriptText: String? = nil,
        images: [PiAgentImageAttachment] = [],
        pasteAttachments: [PiAgentPasteAttachment] = [],
        recordInTranscript: Bool = true
    ) {
        let projectURL = session.launchWorkingDirectory
        // If Pi has already created a session file, always resume it before sending a new prompt.
        // Otherwise an idle follow-up (or a model change followed by Send) starts a fresh Pi session
        // and the chat appears to lose context.
        let canResumePiSession = session.piSessionFile != nil
        Task { @MainActor [weak self] in
            await self?.start(
                session: session,
                projectURL: projectURL,
                initialPrompt: initialPrompt,
                initialTranscriptText: transcriptText,
                initialImages: images,
                initialPasteAttachments: pasteAttachments,
                resumeExisting: canResumePiSession,
                recordInTranscript: recordInTranscript
            )
        }
    }

    func restartForLaunchConfiguration(
        session: PiAgentSessionRecord,
        initialPrompt: String? = nil,
        transcriptText: String? = nil,
        images: [PiAgentImageAttachment] = [],
        pasteAttachments: [PiAgentPasteAttachment] = [],
        recordInTranscript: Bool = true
    ) {
        let projectURL = session.launchWorkingDirectory
        Task { @MainActor [weak self] in
            await self?.start(
                session: session,
                projectURL: projectURL,
                initialPrompt: initialPrompt,
                initialTranscriptText: transcriptText,
                initialImages: images,
                initialPasteAttachments: pasteAttachments,
                resumeExisting: session.piSessionFile != nil,
                recordStopTranscript: false,
                recordInTranscript: recordInTranscript
            )
        }
    }

    func applyLaunchConfigurationChange(sessionID: UUID) {
        requestLaunchResourceRelaunch(sessionID: sessionID)
    }

    func requestLaunchResourceRelaunch(sessionID: UUID, summary: String? = nil) {
        guard clientsBySessionID[sessionID] != nil,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        if let summary {
            recordPendingConfigurationChangeSummary(sessionID: sessionID, summary: summary)
        }
        if session.status.isActive {
            pendingConfigurationRestartSessionIDs.insert(sessionID)
            return
        }
        restartForLaunchConfiguration(session: session)
    }

    func send(
        _ text: String,
        mode: PiAgentInputMode,
        to sessionID: UUID,
        transcriptText displayText: String? = nil,
        images: [PiAgentImageAttachment] = [],
        pasteAttachments: [PiAgentPasteAttachment] = [],
        recordInTranscript: Bool = true
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let message = userMessage(trimmed, images: images)
        // Extension slash commands (e.g. `/blackhole-memory status`) should still hit Pi RPC
        // but must not pollute Deck chat history — same policy as ephemeral notify popups.
        let shouldRecordUser = recordInTranscript
            && !Self.isEphemeralSlashCommandMessage(
                text: displayText ?? trimmed,
                images: images,
                pasteAttachments: pasteAttachments
            )
        cancelPendingIdle(for: sessionID)
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID] else {
            guard store.sessions.first(where: { $0.id == sessionID })?.status == .starting else {
                store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.notRunning"), text: "Resume the session before sending a message."))
                return
            }
            // A launch may await asynchronous resource discovery before it can
            // construct and register PiRPCClient. Keep startup input rather than
            // treating that small window as a stopped session.
            let effectiveMode: PiAgentInputMode = .steer
            if shouldRecordUser {
                let transcriptMessage = displayText.map { userMessage($0, images: images) } ?? message
                store.append(.init(sessionID: sessionID, role: .user, title: transcriptTitle(for: effectiveMode, isStreaming: true), text: transcriptText(transcriptMessage, images: images), rawJSON: transcriptAttachmentJSON(messageText: transcriptMessage, images: images, pasteAttachments: pasteAttachments)))
            }
            pendingStartupInputsBySessionID[sessionID, default: []].append(.init(message: message, images: images))
            return
        }
        let isStreaming = store.sessions.first(where: { $0.id == sessionID })?.status.isActive == true
        let effectiveMode: PiAgentInputMode = isStreaming ? .steer : mode
        if effectiveMode == .prompt,
           pendingConfigurationRestartSessionIDs.remove(sessionID) != nil,
           let session = store.sessions.first(where: { $0.id == sessionID }) {
            restartForLaunchConfiguration(
                session: session,
                initialPrompt: text,
                transcriptText: displayText,
                images: images,
                pasteAttachments: pasteAttachments,
                recordInTranscript: shouldRecordUser
            )
            return
        }
        if shouldRecordUser {
            let transcriptMessage = displayText.map { userMessage($0, images: images) } ?? message
            store.append(.init(sessionID: sessionID, role: .user, title: transcriptTitle(for: effectiveMode, isStreaming: isStreaming), text: transcriptText(transcriptMessage, images: images), rawJSON: transcriptAttachmentJSON(messageText: transcriptMessage, images: images, pasteAttachments: pasteAttachments)))
        }
        // Harmless when Pi is idle, but prevents dropped messages if our local
        // status lags behind Pi's authoritative streaming state. Routed through
        // `prompt` + streamingBehavior rather than the dedicated `steer` type so
        // slash/skill/prompt-template commands still work during streaming.
        let streamingBehavior = effectiveMode == .followUp ? "followUp" : "steer"
        client.prompt(message, images: images, streamingBehavior: streamingBehavior)
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
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.inputNotSent"), text: "Pi Agent is not running, so the response could not be delivered."))
            return
        }
        let request = store.uiRequestsBySessionID[sessionID].flatMap { $0.id == requestID ? $0 : nil }
        client.respondToExtensionUI(id: requestID, value: value)
        if let displayText = request?.nativeAskResponseDisplayText(from: value) {
            store.append(.init(
                sessionID: sessionID,
                role: .user,
                title: PiAgentTranscriptEntry.nativeAskResponseTitle,
                text: displayText
            ))
        }
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
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.inputNotSent"), text: "Pi Agent is not running, so the response could not be delivered."))
            return
        }
        client.confirmExtensionUI(id: requestID, confirmed: confirmed)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func cancelExtensionUI(sessionID: UUID, requestID: String) {
        cancelIdleParking(for: sessionID)
        guard let client = clientsBySessionID[sessionID], client.isRunning else {
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.inputNotSent"), text: "Pi Agent is not running, so the cancellation could not be delivered."))
            return
        }
        client.cancelExtensionUI(id: requestID)
        store.clearUIRequest(sessionID: sessionID, id: requestID)
    }

    func stop(sessionID: UUID, recordTranscript: Bool = true, shouldDiscardPendingStartupInputs: Bool = true) {
        launchGenerationsBySessionID[sessionID] = nil
        cancelLaunchWatchdog(sessionID: sessionID)
        RPCDebugLog.log("DEBUG-STOP stop() called session=\(sessionID.uuidString) hasClient=\(clientsBySessionID[sessionID] != nil)")
        if shouldDiscardPendingStartupInputs {
            discardPendingStartupInputs(sessionID: sessionID, title: LanguageStore.shared.t("run.queuedInputDiscarded"), text: "The session stopped before queued input could be sent")
        }
        cancelIdleParking(for: sessionID)
        clearStreamingState(sessionID: sessionID)
        pendingConfigurationRestartSessionIDs.remove(sessionID)
        pendingConfigurationChangeSummariesBySessionID.removeValue(forKey: sessionID)
        guard let client = clientsBySessionID.removeValue(forKey: sessionID) else {
            clientRunIDsBySessionID[sessionID] = nil
            stoppingClientRunIDsBySessionID[sessionID] = nil
            parkingClientRunIDsBySessionID[sessionID] = nil
            if store.sessions.first(where: { $0.id == sessionID })?.status.isActive == true {
                mark(sessionID, status: .stopped, error: nil)
                if recordTranscript {
                    store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.stopped"), text: "Stop requested. No active Pi Agent process was attached."))
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
            store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.stopped"), text: "Stop requested. Pi Agent received abort and the process is terminating."))
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
        recordPendingConfigurationChangeSummary(
            sessionID: sessionID,
            summary: "model to \(modelDisplayLabel(provider: provider, modelID: modelID))"
        )
        applyLaunchConfigurationChange(sessionID: sessionID)
    }

    func cycleModel(sessionID: UUID) {
        // Model cycling is resolved in AppViewModel so Agent Deck can relaunch with
        // launch-time arguments instead of Pi's default-mutating cycle_model RPC.
    }

    func setThinkingLevel(sessionID: UUID, level: String) {
        let normalized = normalizedThinkingLevel(level) ?? "off"
        store.updateSession(sessionID) { $0.thinkingLevel = normalized }
        // Pin the user's choice so applyState doesn't flip the capsule back to the
        // launch-time level while the in-flight turn keeps reporting it. The
        // deferred relaunch (or stop()) will clear this via clearStreamingState.
        pendingThinkingLevelsBySessionID[sessionID] = .init(requestedLevel: normalized, acknowledgedByPi: true)
        recordPendingConfigurationChangeSummary(
            sessionID: sessionID,
            summary: "thinking level to \(normalized)"
        )
        applyLaunchConfigurationChange(sessionID: sessionID)
    }

    func recordPendingConfigurationChangeSummary(sessionID: UUID, summary: String) {
        // Only meaningful when a live client exists — otherwise no relaunch is
        // about to happen and the summary would never be surfaced.
        guard clientsBySessionID[sessionID] != nil else { return }
        pendingConfigurationChangeSummariesBySessionID[sessionID] = summary
    }

    func modelDisplayLabel(provider: String?, modelID: String?) -> String {
        let p = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p, !p.isEmpty, let m, !m.isEmpty { return "\(p)/\(m)" }
        if let m, !m.isEmpty { return m }
        return "default"
    }

    func compact(session: PiAgentSessionRecord, customInstructions: String? = nil) {
        let messageCount = store.transcript(for: session.id).count(where: { $0.isProviderBackedUserMessage || $0.role == .assistant })
        guard messageCount >= 2 else {
            store.append(.init(sessionID: session.id, role: .status, title: LanguageStore.shared.t("run.compaction"), text: "Nothing to compact"))
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

    /// Forks a session from a specific user message via Pi's native /fork RPC.
    ///
    /// Pi only forks on user messages: it creates a new JSONL session file branched
    /// just before the chosen user message and rebinds its in-process runtime to it.
    /// `userMessageIndex` is the 0-based position of the chosen entry among .user
    /// transcript entries; `userMessageText` is its plain text, used as a sanity
    /// check against Pi's get_fork_messages list.
    ///
    /// If the parent isn't running we auto-resume it first. After Pi responds we
    /// stop the parent client (Pi has already rebound to the fork file in-process,
    /// so the parent is no longer live), then materialize an Agent Deck record
    /// for the new session via store.forkSession — which auto-selects it and
    /// pre-fills its composer with the user-message text.
    func fork(sessionID: UUID, userMessageText: String, userMessageIndex: Int, sourceEntryID: UUID? = nil, rerun: RerunDelivery? = nil) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        guard forkProgressBySessionID[sessionID] == nil else {
            store.append(.init(sessionID: sessionID, role: .status, title: "Fork", text: "A fork is already in progress for this session."))
            return
        }
        let progress = ForkProgress(
            userMessageText: userMessageText,
            userMessageIndex: userMessageIndex,
            sourceEntryID: sourceEntryID,
            rerun: rerun,
            phase: .fetchingMessages,
            getForkMessagesSent: false
        )
        forkProgressBySessionID[sessionID] = progress

        if let client = clientsBySessionID[sessionID], client.isRunning {
            forkProgressBySessionID[sessionID]?.getForkMessagesSent = true
            resetIdleParkingDeadlineIfIdle(sessionID: sessionID)
            client.getForkMessages()
        } else {
            // The auto-resume path: spawn pi for the parent, then once we receive
            // the first get_state response the response handler will send
            // get_fork_messages and continue the state machine.
            resume(session: session)
        }
    }

    func handleForkMessagesResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
        guard var progress = forkProgressBySessionID[sessionID],
              case .fetchingMessages = progress.phase else { return }
        let entries = event.data?["messages"]?.arrayValue ?? []
        let candidates: [(entryId: String, text: String)] = entries.compactMap { value in
            guard let entryId = value["entryId"]?.stringValue,
                  let text = value["text"]?.stringValue,
                  !entryId.isEmpty else { return nil }
            return (entryId, text)
        }
        let target = matchForkEntry(in: candidates, text: progress.userMessageText, index: progress.userMessageIndex)
        guard let target else {
            forkProgressBySessionID[sessionID] = nil
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.forkFailed"), text: "Could not find a matching user message in the Pi session to fork from."))
            return
        }
        progress.phase = .forking
        forkProgressBySessionID[sessionID] = progress
        clientsBySessionID[sessionID]?.fork(entryId: target.entryId)
    }

    func handleForkResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
        guard var progress = forkProgressBySessionID[sessionID],
              case .forking = progress.phase else { return }
        if event.success == false {
            forkProgressBySessionID[sessionID] = nil
            let message = event.error?.compactDescription ?? LanguageStore.shared.t("run.forkFailedBody")
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.forkFailed"), text: message))
            return
        }
        let cancelled = event.data?["cancelled"]?.boolValue ?? false
        let returnedText = event.data?["text"]?.stringValue ?? ""
        if cancelled {
            forkProgressBySessionID[sessionID] = nil
            return
        }
        // Pi's /fork response carries the user-message text it branched from. Prefer
        // that as the composer seed (matches what the terminal interactive mode does);
        // fall back to the local text we passed in.
        let seed = returnedText.isEmpty ? progress.userMessageText : returnedText
        progress.phase = .fetchingState(forkText: seed)
        forkProgressBySessionID[sessionID] = progress
        clientsBySessionID[sessionID]?.getState()
    }

    func handleForkStateResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
        guard let progress = forkProgressBySessionID[sessionID],
              case let .fetchingState(forkText) = progress.phase else { return }
        let sessionFile = event.data?["sessionFile"]?.stringValue ?? ""
        guard !sessionFile.isEmpty else {
            // Pi may take an extra get_state to settle. Re-poll once.
            clientsBySessionID[sessionID]?.getState()
            return
        }
        let sessionId = event.data?["sessionId"]?.stringValue
        let sourceEntryID = progress.sourceEntryID
        let rerun = progress.rerun
        forkProgressBySessionID[sessionID] = nil
        completeFork(parentSessionID: sessionID, newSessionFile: sessionFile, newSessionId: sessionId, composerSeed: forkText, sourceEntryID: sourceEntryID, rerun: rerun)
    }

    func completeFork(parentSessionID: UUID, newSessionFile: String, newSessionId: String?, composerSeed: String, sourceEntryID: UUID? = nil, rerun: RerunDelivery? = nil) {
        guard let parent = store.sessions.first(where: { $0.id == parentSessionID }) else { return }

        if let rerun, let sourceEntryID {
            // In-place re-run: the running pi process has already rebound itself
            // to the branched session file, so the SAME session record rebinds to
            // it too — same row, same client, conversation rewound to just before
            // the chosen message. The dropped tail survives on disk in the parent
            // session file. Resend Pi's own recorded text for the message
            // (byte-identical prompt) with the original entry's attachments.
            store.rewindSession(
                parentSessionID,
                fromEntryID: sourceEntryID,
                newPiSessionFile: newSessionFile,
                newPiSessionId: newSessionId
            )
            if !composerSeed.isEmpty {
                send(
                    composerSeed,
                    mode: .prompt,
                    to: parentSessionID,
                    transcriptText: rerun.transcriptText,
                    images: rerun.images,
                    pasteAttachments: rerun.pasteAttachments,
                )
            }
            return
        }

        // Pi has rebound its runtime to the new session in-process. Stop the parent
        // client (without writing a "Stopped" status to the parent transcript — Pi
        // didn't actually stop, it forked). If the user re-selects the parent later,
        // the resume flow spawns a fresh pi client against the parent's JSONL.
        stop(sessionID: parentSessionID, recordTranscript: false)
        _ = store.forkSession(
            from: parent,
            newPiSessionFile: newSessionFile,
            newPiSessionId: newSessionId,
            composerSeed: composerSeed,
            // Snapshot only the inherited history — turns at/after the forked
            // message never carried over and must not appear in the recap card.
            cutBeforeEntryID: sourceEntryID
        )
    }

    /// Try to map an Agent Deck user-message click to a Pi entryId. Prefer an exact
    /// text match at the same index (most common, no-ambiguity case). Fall back to
    /// the last exact text match (handles transcripts where Pi's user-message list
    /// is shorter or longer than ours, e.g. after compaction). Returns nil if no
    /// text match exists at all.
    func matchForkEntry(in candidates: [(entryId: String, text: String)], text: String, index: Int) -> (entryId: String, text: String)? {
        guard !candidates.isEmpty else { return nil }
        let normalizedTarget = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if index >= 0, index < candidates.count {
            let atIndex = candidates[index]
            if atIndex.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTarget {
                return atIndex
            }
        }
        // Fallback: last exact text match (chronologically most recent).
        if let match = candidates.reversed().first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTarget }) {
            return match
        }
        return nil
    }

    func cycleThinkingLevel(sessionID: UUID) {
        // Thinking cycling is resolved in AppViewModel so Agent Deck can relaunch with
        // launch-time arguments instead of Pi's default-mutating cycle_thinking_level RPC.
    }

    func stopAll(recordTranscript: Bool = true) {
        let sessionIDs = Set(clientsBySessionID.keys).union(
            store.sessions.lazy.filter { $0.status == .starting }.map(\.id)
        )
        for id in sessionIDs {
            stop(sessionID: id, recordTranscript: recordTranscript)
        }
    }
}
