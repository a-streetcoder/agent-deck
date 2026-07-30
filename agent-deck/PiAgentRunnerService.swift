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
    nonisolated private static let logger = Logger(subsystem: "works.earendil.pi-deck", category: "PiRPC")
    /// Number of inbound events still to log after a compaction completes, per session.
    /// Lets us prove whether Pi continues a turn after compaction without logging message content.
    private var postCompactionLogCountBySessionID: [UUID: Int] = [:]
    private let store: PiAgentSessionStore
    private var clientsBySessionID: [UUID: PiRPCClient] = [:]
    private var clientRunIDsBySessionID: [UUID: UUID] = [:]
    /// Identifies the only startup continuation allowed to register a client for
    /// a session. Replaced by a newer resume and invalidated by stop().
    private var launchGenerationsBySessionID: [UUID: UUID] = [:]
    /// Bounds all launch-time preparation before PiRPCClient is registered. Providers
    /// can involve MCP discovery or memory lookup; if one wedges, fail the launch
    /// instead of leaving the session permanently stuck in Starting.
    private var launchWatchdogTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private let launchSetupTimeout: Duration
    /// User input submitted while launch-time setup (such as MCP discovery) is
    /// still awaiting a client. It is recorded immediately, then delivered in
    /// FIFO order after the registered client's initial startup action.
    private struct PendingStartupInput {
        let message: String
        let images: [PiAgentImageAttachment]
    }
    private var pendingStartupInputsBySessionID: [UUID: [PendingStartupInput]] = [:]
    private var afterFinishHookRunIDs: Set<UUID> = []
    private var stoppingClientRunIDsBySessionID: [UUID: UUID] = [:]
    private var parkingClientRunIDsBySessionID: [UUID: UUID] = [:]
    private var assistantEntryIDsBySessionID: [UUID: UUID] = [:]
    private var assistantTextBySessionID: [UUID: String] = [:]
    private var thinkingEntryIDsBySessionID: [UUID: UUID] = [:]
    private var thinkingTextBySessionID: [UUID: String] = [:]
    private var toolEntryIDsByCallID: [String: UUID] = [:]
    /// A tool call's arguments, captured from `tool_execution_start` and kept until
    /// the call ends. The update/end events drop the top-level `args`, but transcript
    /// cards (notably the MCP card, which needs the `server/tool` address that only
    /// lives in `args`) read it off the entry — so we re-attach it to every later
    /// event's rawJSON for this call.
    private var toolStartArgsByCallID: [String: JSONValue] = [:]
    private var compactionEntryIDsBySessionID: [UUID: UUID] = [:]
    private struct PendingThinkingLevel {
        let requestedLevel: String
        var acknowledgedByPi = false
    }

    private var pendingCompactionInstructionsBySessionID: [UUID: String] = [:]
    private var pendingFreeformResponsesBySessionID: [UUID: String] = [:]
    /// Sessions whose transcript we've already reconciled against Pi's session file
    /// on open this launch — keeps the on-view disk read to once per session.
    private var rehydratedFromDiskSessionIDs: Set<UUID> = []
    /// Authoritative Pi messages seen via `get_messages`, live final messages, or
    /// the session JSONL. Category costs are derived only from these messages and
    /// displayed only after they reconcile with `get_session_stats` total cost.
    private var piMessagesBySessionID: [UUID: [JSONValue]] = [:]
    private var pendingThinkingLevelsBySessionID: [UUID: PendingThinkingLevel] = [:]
    /// Re-run: everything needed to resend the forked message exactly as it was
    /// originally sent — the display text and the recorded attachments (images
    /// must re-attach; pastes/issue content is already inline in Pi's recorded
    /// text but is needed for faithful transcript chips).
    struct RerunDelivery {
        var transcriptText: String?
        var images: [PiAgentImageAttachment] = []
        var pasteAttachments: [PiAgentPasteAttachment] = []
    }

    private struct ForkProgress {
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
    private var forkProgressBySessionID: [UUID: ForkProgress] = [:]
    private var pendingConfigurationRestartSessionIDs: Set<UUID> = []
    /// Human-readable summary of the config change driving the next relaunch
    /// (e.g. "thinking level to off"). Set by setModel/setThinkingLevel, consumed
    /// inside start() to seed `.applyingConfigurationChange` on the processing bar
    /// so the user sees why Pi is briefly active.
    private var pendingConfigurationChangeSummariesBySessionID: [UUID: String] = [:]
    private var streamFlushTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var pendingIdleTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// Sessions for which Pi has emitted `agent_start` (or at least `turn_start`) but
    /// not the authoritative `agent_end`. `isStreaming` can be false between turns,
    /// after tool use, compaction, or retries, so it is not by itself a turn-finished signal.
    private var activeAgentRunSessionIDs: Set<UUID> = []
    private var idleParkingTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var idleParkingTimeout: TimeInterval?
    private let idleConfirmationDelay: Duration = .milliseconds(900)
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

    private func restartForLaunchConfiguration(
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

    private func applyLaunchConfigurationChange(sessionID: UUID) {
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

    private func recordPendingConfigurationChangeSummary(sessionID: UUID, summary: String) {
        // Only meaningful when a live client exists — otherwise no relaunch is
        // about to happen and the summary would never be surfaced.
        guard clientsBySessionID[sessionID] != nil else { return }
        pendingConfigurationChangeSummariesBySessionID[sessionID] = summary
    }

    private func modelDisplayLabel(provider: String?, modelID: String?) -> String {
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

    private func handleForkMessagesResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
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

    private func handleForkResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
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

    private func handleForkStateResponse(_ event: PiAgentRPCEvent, sessionID: UUID) {
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

    private func completeFork(parentSessionID: UUID, newSessionFile: String, newSessionId: String?, composerSeed: String, sourceEntryID: UUID? = nil, rerun: RerunDelivery? = nil) {
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
    private func matchForkEntry(in candidates: [(entryId: String, text: String)], text: String, index: Int) -> (entryId: String, text: String)? {
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

    private func start(
        session: PiAgentSessionRecord,
        projectURL: URL,
        initialPrompt: String?,
        initialTranscriptText: String? = nil,
        initialImages: [PiAgentImageAttachment] = [],
        initialPasteAttachments: [PiAgentPasteAttachment] = [],
        resumeExisting: Bool = false,
        recordStopTranscript: Bool = true,
        recordInTranscript: Bool = true
    ) async {
        // stop() → clearStreamingState wipes processing activity, so capture the
        // pending summary first and re-apply it below once the new run is staged.
        let configurationChangeSummary = pendingConfigurationChangeSummariesBySessionID.removeValue(forKey: session.id)
        stop(sessionID: session.id, recordTranscript: recordStopTranscript, shouldDiscardPendingStartupInputs: false)
        let launchGeneration = UUID()
        launchGenerationsBySessionID[session.id] = launchGeneration
        scheduleLaunchWatchdog(sessionID: session.id, generation: launchGeneration)
        cancelIdleParking(for: session.id)
        parkingClientRunIDsBySessionID[session.id] = nil
        stoppingClientRunIDsBySessionID[session.id] = nil
        mark(session.id, status: .starting, error: nil)
        if let configurationChangeSummary {
            store.setProcessingActivity(.applyingConfigurationChange(summary: configurationChangeSummary), for: session.id)
        }
        let trimmedInitialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedInitialPrompt.isEmpty || !initialImages.isEmpty {
            let message = userMessage(trimmedInitialPrompt, images: initialImages)
            let shouldRecordUser = recordInTranscript
                && !Self.isEphemeralSlashCommandMessage(
                    text: initialTranscriptText ?? trimmedInitialPrompt,
                    images: initialImages,
                    pasteAttachments: initialPasteAttachments
                )
            if shouldRecordUser {
                let transcriptMessage = initialTranscriptText.map { userMessage($0, images: initialImages) } ?? message
                store.append(.init(sessionID: session.id, role: .user, title: LanguageStore.shared.t("run.initialPrompt"), text: transcriptText(transcriptMessage, images: initialImages), rawJSON: transcriptAttachmentJSON(messageText: transcriptMessage, images: initialImages, pasteAttachments: initialPasteAttachments)))
            }
        }

        // For agent-chat sessions, resolve the bound agent up-front so we can
        // fail fast with a transcript error before spawning anything.
        let boundAgent: EffectiveAgentRecord? = session.isAgentBound ? boundAgentProvider?(session) : nil
        if session.isAgentBound, boundAgent == nil {
            launchGenerationsBySessionID[session.id] = nil
            discardPendingStartupInputs(sessionID: session.id, title: LanguageStore.shared.t("run.queuedInputNotSent"), text: LanguageStore.shared.t("run.launchPrepTimedOutBody"))
            let missingName = session.agentName ?? "?"
            mark(session.id, status: .failed, error: LanguageStore.shared.t("run.agentNoLongerAvailable", missingName))
            store.append(.init(
                sessionID: session.id,
                role: .error,
                title: LanguageStore.shared.t("run.agentUnavailable"),
                text: LanguageStore.shared.t("run.agentUnavailableBody", missingName)
            ))
            return
        }
        if let boundAgent, boundAgent.resolved.disabled == true {
            launchGenerationsBySessionID[session.id] = nil
            discardPendingStartupInputs(sessionID: session.id, title: LanguageStore.shared.t("run.queuedInputNotSent"), text: LanguageStore.shared.t("run.launchPrepTimedOutBody"))
            mark(session.id, status: .failed, error: LanguageStore.shared.t("run.agentDisabledText", boundAgent.name))
            store.append(.init(
                sessionID: session.id,
                role: .error,
                title: LanguageStore.shared.t("run.agentDisabled"),
                text: LanguageStore.shared.t("run.agentDisabledBody", boundAgent.name)
            ))
            return
        }

        do {
            if session.isNoProject {
                migrateLegacyGeneralChatScratchFolderIfNeeded(for: session, targetURL: projectURL)
            }
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let launchSettings = AppSettingsStore.shared.settings
            // `--no-extensions` + re-inject model provider packages (pi-grok-cli, …).
            var extraArguments: [String] = PiAgentLaunchArgumentBuilder.isolatedLaunchBaseArguments(
                settings: launchSettings,
                projectURL: projectURL
            )
            if let auditURL = try? PiNativeSubagentBridgeExtensions.systemPromptAuditExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", auditURL.path])
            }
            if let askURL = try? PiNativeSubagentBridgeExtensions.askUserExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", askURL.path])
            }
            if !session.isNoProject,
               AppSettingsStore.shared.settings.agentMemoryEnabled,
               let memoryURL = try? PiNativeSubagentBridgeExtensions.memoryExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", memoryURL.path])
            }
            if let fastURL = try? PiNativeSubagentBridgeExtensions.openAIFastExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", fastURL.path])
            }
            if !session.isNoProject {
                for commandURL in PiInjectedCommandCatalog.extensionURLs(settings: AppSettingsStore.shared.settings) {
                    extraArguments.append(contentsOf: ["--extension", commandURL.path])
                }
            }
            let sessionID = session.id
            let clientRunID = UUID()
            let environment = EnvRuntimeEnvironment().environment(
                extra: [
                    "AGENT_DECK_PARENT_SESSION_ID": session.id.uuidString,
                    "AGENT_DECK_OPENAI_FAST_CONFIG": PiNativeSubagentBridgeExtensions.openAIFastConfigURL().path
                ]
            )
            // Agent Deck parent append prompts (Deck-agent catalog, then memory).
            // Collected here and emitted once below so the active APPEND_SYSTEM.md is
            // preserved a single time, regardless of how many features contribute.
            var agentDeckAppendPrompts: [String] = []
            // Resolve the session's MCP catalog once so both the bound-agent tool
            // allowlist decision and the append below reuse the same discovery. The
            // provider discovers on demand for sessions in a project other than the
            // active one, so their assigned servers are connected even when the
            // active-project snapshot wouldn't cover them.
            let mcpCatalog = await mcpCatalogProvider?(session)
            guard isCurrentLaunch(sessionID: session.id, generation: launchGeneration) else { return }
            if session.isAgentDeckBuilderSession {
                extraArguments.append(contentsOf: [
                    "--system-prompt", AgentDeckBuilderPrompt.text,
                    "--append-system-prompt", ""
                ])
            }
            if let boundAgent {
                // 1:1 agent chat: launch Pi with the agent's raw system prompt,
                // its tool allowlist (minus `contact_supervisor` — there's no
                // supervisor above the user), and its agent-defined extensions
                // on top of the user-extension stack we already emitted.
                // Importantly: no `managed_subagent` bridge, no agent catalog
                // appended to the system prompt, no child-boundary boilerplate.
                let exaConfigured = PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment)
                let webFetchInstalled = WebFetchDependencyService().status().isInstalled
                let memoryEnabled = AppSettingsStore.shared.settings.agentMemoryEnabled
                extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.systemPromptArguments(
                    for: boundAgent,
                    prompt: boundAgent.resolved.systemPrompt
                ))
                extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.toolArguments(.init(
                    agent: boundAgent,
                    includeSupervisorTool: false,
                    includeMemoryTools: memoryEnabled,
                    includeExaTools: exaConfigured,
                    includeFallbackWebFetchTool: !exaConfigured && webFetchInstalled,
                    // The native `mcp` bridge is injected below when the agent has
                    // in-scope servers; a restrictive allowlist must include it.
                    includeMCPTool: mcpCatalog?.isEmpty == false
                )))
                // Share the single `--no-extensions` already at the top of
                // extraArguments; only append the agent's authored extensions.
                extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.agentExtensionArguments(
                    for: boundAgent,
                    prependNoExtensions: false
                ))
            } else if !session.isNoProject,
                      session.subagentsEnabled,
                      let catalog = nativeSubagentCatalogProvider?(session), !catalog.isEmpty,
                      let bridgeURL = try? PiNativeSubagentBridgeExtensions.parentExtensionURL() {
                // The subagent bridge and its catalog are injected together. If the
                // session has no selected agents (or none are available), the
                // catalog is empty and the session launches exactly as if subagents
                // were turned off — no bridge extension, no system-prompt block.
                extraArguments.append(contentsOf: ["--extension", bridgeURL.path])
                agentDeckAppendPrompts.append(catalog)
            }
            // Native MCP bridge + catalog, injected together and independently of Deck
            // agents. When no MCP servers are assigned the provider returns nil and the
            // session launches exactly as if MCP were off — no bridge, no prompt block.
            // Loaded before user extensions below so the `mcp` tool wins any conflict.
            // `mcpCatalog` is resolved once above the bound-agent branch so the tool
            // allowlist decision and the append both reuse the same discovery.
            if let mcpCatalog, !mcpCatalog.isEmpty,
               let mcpURL = try? PiNativeSubagentBridgeExtensions.mcpExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", mcpURL.path])
                agentDeckAppendPrompts.append(mcpCatalog)
            }
            extraArguments.append("--no-skills")
            if let boundAgent {
                if let boundAgentSkillArgumentsProvider {
                    extraArguments.append(contentsOf: try boundAgentSkillArgumentsProvider(boundAgent))
                }
            } else if session.isAgentDeckBuilderSession {
                if let agentDeckBuilderSkillArgumentsProvider {
                    extraArguments.append(contentsOf: try agentDeckBuilderSkillArgumentsProvider())
                }
            } else if !session.isNoProject,
                      let parentSkillArgumentsProvider {
                extraArguments.append(contentsOf: try parentSkillArgumentsProvider(projectURL))
            }
            extraArguments.append("--no-prompt-templates")
            extraArguments.append("--no-themes")
            if !session.isNoProject,
               let parentPromptTemplateArgumentsProvider {
                extraArguments.append(contentsOf: try parentPromptTemplateArgumentsProvider(projectURL))
            }
            if !session.isNoProject,
               let parentMemoryAppendPromptsProvider {
                agentDeckAppendPrompts.append(contentsOf: try await parentMemoryAppendPromptsProvider(session, initialPrompt))
                guard isCurrentLaunch(sessionID: session.id, generation: launchGeneration) else { return }
            }
            // Single APPEND_SYSTEM.md preservation point. Pi disables automatic
            // APPEND_SYSTEM.md discovery as soon as any explicit append is passed, so
            // this resolver re-adds the active file once and then stacks the catalog
            // and memory prompts in order. Emitting it per feature double-injected it.
            if session.isNoProject {
                for prompt in agentDeckAppendPrompts where !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    extraArguments.append(contentsOf: ["--append-system-prompt", prompt])
                }
            } else {
                extraArguments.append(contentsOf: PiParentAppendPromptResolver.appendSystemPromptArguments(
                    projectURL: projectURL,
                    agentDeckAppendPrompts: agentDeckAppendPrompts
                ))
            }
            let launchConfiguration = self.launchConfiguration(for: session, boundAgent: boundAgent)
            if PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment) {
                if let webURL = try? PiNativeSubagentBridgeExtensions.webAccessExtensionURL() {
                    extraArguments.append(contentsOf: ["--extension", webURL.path])
                }
            } else if WebFetchDependencyService().status().isInstalled,
                      let webURL = try? PiNativeSubagentBridgeExtensions.fallbackWebFetchExtensionURL() {
                extraArguments.append(contentsOf: ["--extension", webURL.path])
            }
            // User-selected Pi extensions load LAST so every Agent Deck bridge above
            // registers first and wins any tool-name conflict (e.g. ask_user, web_search).
            if !session.isNoProject {
                extraArguments.append(contentsOf: PiAgentLaunchArgumentBuilder.userSelectedExtensionArguments(
                    settings: launchSettings,
                    projectURL: projectURL
                ))
            }
            var injectedExtensionPaths: [String] = []
            for i in 0..<(extraArguments.count - 1) {
                if extraArguments[i] == "--extension" {
                    injectedExtensionPaths.append(extraArguments[i + 1])
                }
            }
            guard isCurrentLaunch(sessionID: session.id, generation: launchGeneration) else { return }
            try AgentDeckBuiltinHooks.preLaunch(.init(
                session: session,
                projectURL: projectURL,
                extraArguments: extraArguments,
                environment: environment
            ))
            afterFinishHookRunIDs.remove(clientRunID)
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
            cancelLaunchWatchdog(sessionID: session.id)
            clientsBySessionID[session.id] = client
            clientRunIDsBySessionID[session.id] = clientRunID
            store.updateSession(session.id) { record in
                record.launchCommand = client.launchCommand
                record.status = .running
                record.injectedExtensions = injectedExtensionPaths.isEmpty ? nil : injectedExtensionPaths
                // Stamped per launch: memory injection (recall prompts, memory
                // tools) is decided by the global setting at process start, so
                // the resources popover can report what this run actually got.
                record.memoryEnabled = !session.isNoProject && AppSettingsStore.shared.settings.agentMemoryEnabled
            }
            client.getState()
            client.getCommands()
            onSessionLaunched?(session.id)
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
            drainPendingStartupInputs(sessionID: session.id, client: client)
        } catch {
            guard isCurrentLaunch(sessionID: session.id, generation: launchGeneration) else { return }
            cancelLaunchWatchdog(sessionID: session.id)
            launchGenerationsBySessionID[session.id] = nil
            discardPendingStartupInputs(sessionID: session.id, title: LanguageStore.shared.t("run.queuedInputNotSent"), text: "Pi Agent failed to launch before queued input could be sent")
            mark(session.id, status: .failed, error: error.localizedDescription)
            store.append(.init(sessionID: session.id, role: .error, title: LanguageStore.shared.t("run.launchFailed"), text: error.localizedDescription))
        }
    }

    private func isCurrentLaunch(sessionID: UUID, generation: UUID) -> Bool {
        launchGenerationsBySessionID[sessionID] == generation
    }

    private func scheduleLaunchWatchdog(sessionID: UUID, generation: UUID) {
        cancelLaunchWatchdog(sessionID: sessionID)
        launchWatchdogTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.launchSetupTimeout)
            } catch {
                return
            }
            guard self.isCurrentLaunch(sessionID: sessionID, generation: generation),
                  self.clientsBySessionID[sessionID] == nil else { return }
            self.launchWatchdogTasksBySessionID[sessionID] = nil
            self.launchGenerationsBySessionID[sessionID] = nil
            self.discardPendingStartupInputs(
                sessionID: sessionID,
                title: LanguageStore.shared.t("run.queuedInputNotSent"),
                text: LanguageStore.shared.t("run.launchPrepTimedOutBody")
            )
            self.mark(sessionID, status: .failed, error: LanguageStore.shared.t("run.launchPrepTimedOut"))
            self.store.append(.init(
                sessionID: sessionID,
                role: .error,
                title: LanguageStore.shared.t("run.launchTimedOut"),
                text: "Agent Deck could not finish launch preparation within 45 seconds. Pi was not started and the session file was not changed. Retry the session; if this repeats, test or temporarily unassign its MCP servers."
            ))
        }
    }

    private func cancelLaunchWatchdog(sessionID: UUID) {
        launchWatchdogTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
    }

    private func drainPendingStartupInputs(sessionID: UUID, client: PiRPCClient) {
        let inputs = pendingStartupInputsBySessionID.removeValue(forKey: sessionID) ?? []
        for input in inputs {
            client.prompt(input.message, images: input.images, streamingBehavior: "steer")
        }
    }

    private func discardPendingStartupInputs(sessionID: UUID, title: String, text: String) {
        guard let inputs = pendingStartupInputsBySessionID.removeValue(forKey: sessionID), !inputs.isEmpty else { return }
        store.append(.init(sessionID: sessionID, role: .status, title: title, text: "\(text). \(inputs.count) \(inputs.count == 1 ? "message was" : "messages were") not delivered."))
    }

    private func migrateLegacyGeneralChatScratchFolderIfNeeded(for session: PiAgentSessionRecord, targetURL: URL) {
        let legacyURL = session.legacyNoProjectLaunchWorkingDirectory
        let fileManager = FileManager.default
        guard legacyURL.standardizedFileURL.path != targetURL.standardizedFileURL.path,
              fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: targetURL.path) else { return }
        try? fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacyURL, to: targetURL)
    }

    private func launchConfiguration(for session: PiAgentSessionRecord) -> (provider: String?, model: String?, thinkingLevel: String?) {
        launchConfiguration(for: session, boundAgent: nil)
    }

    /// Resolves the provider/model/thinking-level triple Pi should be launched with.
    /// User overrides win first; otherwise the session's last-known model is used.
    /// For agent-bound sessions, when no user override is set, the agent's
    /// `resolved.model` / `resolved.thinking` (resolved by `PiSubagentLaunchPlanner`)
    /// becomes the default — letting the agent author dictate the model.
    private func launchConfiguration(for session: PiAgentSessionRecord, boundAgent: EffectiveAgentRecord?) -> (provider: String?, model: String?, thinkingLevel: String?) {
        let overrideProvider = firstNonEmpty(session.modelOverrideProvider)
        let overrideModel = firstNonEmpty(session.modelOverrideID)
        if overrideModel != nil {
            // User override wins regardless of bound agent.
            let provider = firstNonEmpty(overrideProvider, session.modelProvider)
            let model = firstNonEmpty(overrideModel, session.model)
            return (provider, model, normalizedThinkingLevel(session.thinkingLevel))
        }
        if let boundAgent {
            let selection = PiSubagentLaunchPlanner.modelSelection(for: boundAgent, parentSession: session)
            let provider = firstNonEmpty(selection.provider, session.modelProvider)
            let model = firstNonEmpty(selection.modelArgument, session.model)
            let thinking = normalizedThinkingLevel(boundAgent.resolved.thinking ?? session.thinkingLevel)
            return (provider, model, thinking)
        }
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
        guard !activeAgentRunSessionIDs.contains(sessionID),
              let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status.isActive,
              store.uiRequestsBySessionID[sessionID] == nil,
              assistantEntryIDsBySessionID[sessionID] == nil,
              assistantTextBySessionID[sessionID] == nil,
              thinkingEntryIDsBySessionID[sessionID] == nil,
              thinkingTextBySessionID[sessionID] == nil else { return }
        mark(sessionID, status: .idle, error: nil)
        // Launch-affecting config changes (model/thinking) requested mid-turn are
        // queued in pendingConfigurationRestartSessionIDs. Drain that here so the
        // new argv is applied at turn-end — otherwise it only takes effect on the
        // next user prompt, and the capsule misrepresents the live process.
        if pendingConfigurationRestartSessionIDs.remove(sessionID) != nil,
           let refreshed = store.sessions.first(where: { $0.id == sessionID }) {
            restartForLaunchConfiguration(session: refreshed)
            onTurnFinished?(sessionID)
            return
        }
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

    /// Pure extension slash commands (`/blackhole-memory status`, chip+args) should not
    /// appear in Deck chat history. Skills (`/skill:…`), prompts, and free text still do.
    ///
    /// - Parameters:
    ///   - text: Visible or RPC message text. Required.
    ///   - images: Image attachments. Required (empty means none).
    ///   - pasteAttachments: Paste blobs. Required (empty means none).
    /// - Returns: `true` when Deck should omit the user bubble from transcript/disk.
    nonisolated static func isEphemeralSlashCommandMessage(
        text: String,
        images: [PiAgentImageAttachment],
        pasteAttachments: [PiAgentPasteAttachment]
    ) -> Bool {
        guard images.isEmpty, pasteAttachments.isEmpty else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard line.hasPrefix("/") else { return false }
            // Active skill invocations are real turns and should remain in history.
            if line.lowercased().hasPrefix("/skill:") { return false }
            return true
        }
    }

    /// Builds the canonical Pi RPC prompt. Attachment-only transcript labels are
    /// projected by the renderer and must never change this source text.
    private func userMessage(_ text: String, images: [PiAgentImageAttachment]) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !images.isEmpty else { return base }

        // A re-run receives Pi's original message text as its composer seed and
        // the original image payloads separately. That text already contains the
        // image file tags, so append only tags that are not already represented.
        // The payloads are still passed to PiRPCClient unchanged.
        var existingTagCounts: [String: Int] = [:]
        for image in images {
            let tag = imageFileTag(for: image)
            existingTagCounts[tag] = base.components(separatedBy: tag).count - 1
        }
        var emittedTagCounts: [String: Int] = [:]
        let missingTags = images.compactMap { image -> String? in
            let tag = imageFileTag(for: image)
            let emittedCount = emittedTagCounts[tag, default: 0]
            emittedTagCounts[tag] = emittedCount + 1
            return emittedCount < existingTagCounts[tag, default: 0] ? nil : tag
        }
        guard !missingTags.isEmpty else { return base }
        let fileTags = missingTags.joined(separator: "\n")
        return base.isEmpty ? fileTags : "\(base)\n\n\(fileTags)"
    }

    private func imageFileTag(for image: PiAgentImageAttachment) -> String {
        "<file name=\"\(image.fileReference ?? image.name)\">\(image.dimensionNote ?? "")</file>"
    }

    private func transcriptTitle(for mode: PiAgentInputMode, isStreaming: Bool) -> String {
        guard isStreaming else { return LanguageStore.shared.t("run.prompt") }
        switch mode {
        case .prompt, .steer: return LanguageStore.shared.t("run.steering")
        case .followUp: return LanguageStore.shared.t("run.queuedFollowUp")
        }
    }

    private func transcriptText(_ text: String, images: [PiAgentImageAttachment]) -> String {
        visibleUserText(text, imageReferences: Set(images.compactMap { $0.fileReference ?? $0.name }))
    }

    private func transcriptAttachmentJSON(messageText: String?, images: [PiAgentImageAttachment], pasteAttachments: [PiAgentPasteAttachment] = []) -> String? {
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
        if let messageText {
            let files = extractedFileAttachments(in: messageText, imageReferences: Set(images.compactMap { $0.fileReference ?? $0.name }))
            if !files.isEmpty {
                payload["files"] = files.map { ["name": $0.name, "path": $0.path] }
            }
        }
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Non-image `<file name="path"></file>` tags carried inline in the user
    /// message. Used to carry real file paths into the transcript JSON so the
    /// in-bubble pill popover can preview text/markdown/html/code without
    /// changing what we send to Pi over RPC.
    private func extractedFileAttachments(in text: String, imageReferences: Set<String>) -> [(name: String, path: String)] {
        let pattern = #"<file name=\"([^\"]+)\">[\s\S]*?</file>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var out: [(name: String, path: String)] = []
        for match in regex.matches(in: text, range: range) {
            let path = (text as NSString).substring(with: match.range(at: 1))
            if imageReferences.contains(path) { continue }
            let basename = URL(fileURLWithPath: path).lastPathComponent
            if imageReferences.contains(basename) { continue }
            guard seen.insert(path).inserted else { continue }
            out.append((name: basename, path: path))
        }
        return out
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
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.connectionError"), text: message))
            // The RPC websocket died mid-turn, so no turn_end/message_end will arrive to
            // schedule idle confirmation, and the local Pi process may keep running so
            // handleTermination never fires either. Without this the session is stranded
            // in .running ("active" with nothing streaming) until the app is restarted.
            // Wipe the stale streaming buffers and move the session to a terminal state.
            clearStreamingState(sessionID: sessionID)
            mark(sessionID, status: .failed, error: message)
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
        RPCDebugLog.log("event type=\(event?.type ?? "unparsed") cmd=\(event?.command ?? "-")")
        // Within the window after a compaction completes, log the type of each inbound
        // event (never its content) so we can confirm whether Pi continues the turn.
#if DEBUG
        if let remaining = postCompactionLogCountBySessionID[sessionID], remaining > 0 {
            let type = event?.type ?? "unparsed"
            Self.logger.info("Post-compaction inbound event type=\(type, privacy: .public)")
            if remaining <= 1 {
                postCompactionLogCountBySessionID[sessionID] = nil
            } else {
                postCompactionLogCountBySessionID[sessionID] = remaining - 1
            }
        }
#endif
        guard let event else {
            store.append(.init(sessionID: sessionID, role: .raw, title: LanguageStore.shared.t("run.rawOutput"), text: rawLine))
            return
        }

        switch event.type {
        case "response":
            handleResponse(event, rawLine: rawLine, sessionID: sessionID)
        case "agent_start", "turn_start":
            activeAgentRunSessionIDs.insert(sessionID)
            cancelPendingIdle(for: sessionID)
            cancelIdleParking(for: sessionID)
            mark(sessionID, status: .running, error: nil)
            if event.type == "turn_start" {
                let entryID = UUID()
                assistantEntryIDsBySessionID[sessionID] = entryID
                assistantTextBySessionID[sessionID] = ""
                thinkingEntryIDsBySessionID[sessionID] = nil
                thinkingTextBySessionID[sessionID] = nil
                store.upsert(.init(id: entryID, sessionID: sessionID, role: .assistant, title: LanguageStore.shared.t("run.assistant"), text: "", rawJSON: nil))
                store.setProcessingActivity(.preparing, for: sessionID)
            }
        case "agent_end", "turn_end":
            if event.type == "agent_end" {
                activeAgentRunSessionIDs.remove(sessionID)
            }
            // Some Pi RPC streams include the final assistant message on turn_end/agent_end
            // without a separate message_end. Finalize it here so stale streaming buffers
            // do not keep the session card stuck in the active/running state.
            if let message = finalAssistantMessage(from: event) {
                finalizeCompletedMessage(message, rawLine: rawLine, sessionID: sessionID)
            }
            if event.type == "agent_end" {
                scheduleIdleConfirmation(sessionID: sessionID)
                clientsBySessionID[sessionID]?.getMessages()
            }
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
        case "message_update":
            cancelPendingIdle(for: sessionID)
            handleMessageUpdate(event, rawLine: rawLine, sessionID: sessionID)
        case "message_end":
            handleMessageEnd(event, rawLine: rawLine, sessionID: sessionID)
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            cancelPendingIdle(for: sessionID)
            mark(sessionID, status: .running, error: nil)
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
        // Surface failed fork responses to the user but keep the normal failure path
        // out of the way so it doesn't append a generic "RPC Error" on cancel paths.
        if event.success == false, event.command == "fork", forkProgressBySessionID[sessionID] != nil {
            handleForkResponse(event, sessionID: sessionID)
            return
        }
        // Failed get_fork_messages aborts the fork state machine cleanly so retries work.
        if event.success == false, event.command == "get_fork_messages", forkProgressBySessionID[sessionID] != nil {
            forkProgressBySessionID[sessionID] = nil
            let message = event.error?.compactDescription ?? "Could not fetch fork candidates from Pi."
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.forkFailed"), text: message))
            return
        }
        if event.success == false {
            if event.command == "set_thinking_level" || event.command == "cycle_thinking_level" {
                pendingThinkingLevelsBySessionID[sessionID] = nil
            }
            let message = event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine
            mark(sessionID, status: .failed, error: message)
            store.append(.init(sessionID: sessionID, role: .error, title: event.command ?? "RPC Error", text: message, rawJSON: rawLine))
            return
        }

        // Fork state-machine branches (must run before the generic get_state path so
        // we don't accidentally write the fork's new sessionFile onto the parent record).
        if event.command == "get_fork_messages", forkProgressBySessionID[sessionID] != nil {
            handleForkMessagesResponse(event, sessionID: sessionID)
            return
        }
        if event.command == "fork", forkProgressBySessionID[sessionID] != nil {
            handleForkResponse(event, sessionID: sessionID)
            return
        }
        if event.command == "get_state",
           let progress = forkProgressBySessionID[sessionID],
           case .fetchingState = progress.phase {
            handleForkStateResponse(event, sessionID: sessionID)
            return
        }

        if event.command == "get_state", let data = event.data {
            applyState(data, to: sessionID)
            // Auto-resume path for fork: a fresh pi client just came up after we
            // called resume() inside fork(). Now that there is a live client, kick
            // off the get_fork_messages we deferred.
            if var progress = forkProgressBySessionID[sessionID],
               case .fetchingMessages = progress.phase,
               !progress.getForkMessagesSent,
               let client = clientsBySessionID[sessionID],
               client.isRunning {
                progress.getForkMessagesSent = true
                forkProgressBySessionID[sessionID] = progress
                client.getForkMessages()
            }
            return
        }

        if event.command == "get_commands", let data = event.data {
            let runtime = parseRuntimeSlashCommands(from: data)
            store.updateSession(sessionID) { record in
                record.runtimeSlashCommands = runtime.isEmpty ? nil : runtime
                record.commandInvocations = runtime.isEmpty
                    ? nil
                    : Array(Set(runtime.map(\.invocation))).sorted()
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

        if event.command == "get_messages" {
            let messages = event.messages?.arrayValue
                ?? event.data?["messages"]?.arrayValue
                ?? event.data?.arrayValue
                ?? []
            piMessagesBySessionID[sessionID] = messages
            applyVerifiedCostBreakdownIfPossible(sessionID: sessionID, messages: messages)
            applyRehydratedMessages(messages, sessionID: sessionID)
            return
        }

        if event.command == "get_session_stats", let data = event.data {
            store.updateSession(sessionID) { record in
                record.lastSummary = data.compactDescription
                record.inputTokens = data["tokens"]?["input"]?.flexibleNumber.map(Int.init)
                record.outputTokens = data["tokens"]?["output"]?.flexibleNumber.map(Int.init)
                record.cacheReadTokens = data["tokens"]?["cacheRead"]?.flexibleNumber.map(Int.init)
                record.cacheWriteTokens = data["tokens"]?["cacheWrite"]?.flexibleNumber.map(Int.init)
                record.totalTokens = data["tokens"]?["total"]?.flexibleNumber.map(Int.init)
                record.toolCalls = data["toolCalls"]?.flexibleNumber.map(Int.init)
                record.toolResults = data["toolResults"]?.flexibleNumber.map(Int.init)
                if let costBreakdown = PiAgentUsageCostBreakdown.from(data["cost"]) {
                    record.cost = costBreakdown.resolvedTotal
                    record.costBreakdown = PiAgentUsageCostBreakdown.verifiedAssistantCategoryCosts(
                        from: piMessagesBySessionID[sessionID] ?? [],
                        statsTotalCost: costBreakdown.resolvedTotal
                    )
                } else {
                    record.costBreakdown = nil
                }
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
            "subagentResults": "Deck agent results",
            "subagent_results": "Deck agent results",
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
        guard let first = spaced.first else { return LanguageStore.shared.t("run.context") }
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
            record.recordPiSessionFile(data["sessionFile"]?.stringValue)
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
                let prevStatus = String(describing: record.status)
                RPCDebugLog.log("DEBUG-STOP applyState isStreaming=true -> .running (prev=\(prevStatus)) session=\(sessionID.uuidString)")
                cancelPendingIdle(for: sessionID)
                cancelIdleParking(for: sessionID)
                record.status = .running
            } else if record.status.isActive, !activeAgentRunSessionIDs.contains(sessionID) {
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

    /// Parses Pi RPC `get_commands` payload into rich slash catalog entries.
    ///
    /// - Parameter value: RPC `data` object (`{ commands: [...] }`) or a bare array.
    /// - Returns: Deduplicated commands keyed by bare name (first wins), sorted by name.
    private func parseRuntimeSlashCommands(from value: JSONValue) -> [PiRuntimeSlashCommand] {
        let commands: [JSONValue]
        if case let .array(items) = value {
            commands = items
        } else if case let .array(items)? = value["commands"] {
            commands = items
        } else {
            commands = []
        }

        var seen = Set<String>()
        var parsed: [PiRuntimeSlashCommand] = []
        for item in commands {
            let raw = item["name"]?.stringValue ?? item["invocation"]?.stringValue ?? item.stringValue
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let bare = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
            guard seen.insert(bare).inserted else { continue }
            let description = item["description"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = (item["source"]?.stringValue ?? "extension")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            parsed.append(
                PiRuntimeSlashCommand(
                    name: bare,
                    description: (description?.isEmpty == false) ? description : nil,
                    source: source.isEmpty ? "extension" : source
                )
            )
        }
        return parsed.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func parseCommandInvocations(from value: JSONValue) -> [String] {
        Array(Set(parseRuntimeSlashCommands(from: value).map(\.invocation))).sorted()
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
                store.setProcessingActivity(.reasoning, for: sessionID)
                scheduleStreamingFlush(sessionID: sessionID)
            } else {
                let entryID = assistantEntryIDsBySessionID[sessionID] ?? UUID()
                assistantEntryIDsBySessionID[sessionID] = entryID
                assistantTextBySessionID[sessionID, default: ""] += delta
                store.setProcessingActivity(.responding, for: sessionID)
                scheduleStreamingFlush(sessionID: sessionID)
            }
        case "toolcall_start":
            break
        case "error":
            store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.assistantError"), text: assistantEvent.compactDescription, rawJSON: rawLine))
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
        let characterCount = (assistantTextBySessionID[sessionID]?.count ?? 0) + (thinkingTextBySessionID[sessionID]?.count ?? 0)
        return Self.streamingFlushDelay(
            isSelected: store.selectedSessionID == sessionID,
            characterCount: characterCount
        )
    }

    /// The selected transcript owns the visible streaming cadence. Background sessions
    /// retain an adaptive policy so they do not spend the same UI budget on unseen work.
    static func streamingFlushDelay(isSelected: Bool, characterCount: Int) -> UInt64 {
        if isSelected {
            return 33_000_000 // ~30 fps
        }
        switch characterCount {
        case 0..<1_000:
            return 33_000_000 // ~30 fps
        case 1_000..<4_000:
            return 45_000_000 // ~22 fps
        default:
            return 60_000_000 // ~17 fps
        }
    }

    private func flushStreamingEntries(sessionID: UUID) {
        if let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID],
           let thinkingText = thinkingTextBySessionID[sessionID],
           !thinkingText.isEmpty {
            let display = TextSanitizer.sanitizeThinking(thinkingText)
            if !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.upsert(.init(
                    id: thinkingEntryID,
                    sessionID: sessionID,
                    role: .thinking,
                    title: LanguageStore.shared.t("run.thinking"),
                    text: display,
                    rawJSON: nil
                ), before: assistantEntryIDsBySessionID[sessionID], persist: false, revisionPolicy: .immediateForSelectedSession)
            }
        }

        if let assistantEntryID = assistantEntryIDsBySessionID[sessionID],
           let assistantText = assistantTextBySessionID[sessionID] {
            store.upsert(.init(
                id: assistantEntryID,
                sessionID: sessionID,
                role: .assistant,
                title: LanguageStore.shared.t("run.assistant"),
                text: TextSanitizer.sanitizeAnswer(assistantText),
                rawJSON: nil
            ), persist: false, revisionPolicy: .immediateForSelectedSession)
        }
    }

    private func clearStreamingState(sessionID: UUID) {
        idleParkingTasksBySessionID[sessionID]?.cancel()
        idleParkingTasksBySessionID[sessionID] = nil
        streamFlushTasksBySessionID[sessionID]?.cancel()
        streamFlushTasksBySessionID[sessionID] = nil
        store.setProcessingActivity(nil, for: sessionID)
        assistantEntryIDsBySessionID[sessionID] = nil
        assistantTextBySessionID[sessionID] = nil
        thinkingEntryIDsBySessionID[sessionID] = nil
        thinkingTextBySessionID[sessionID] = nil
        pendingFreeformResponsesBySessionID[sessionID] = nil
        pendingThinkingLevelsBySessionID[sessionID] = nil
        activeAgentRunSessionIDs.remove(sessionID)
        let keyPrefix = "\(sessionID.uuidString):"
        toolEntryIDsByCallID = toolEntryIDsByCallID.filter { !$0.key.hasPrefix(keyPrefix) }
        toolStartArgsByCallID = toolStartArgsByCallID.filter { !$0.key.hasPrefix(keyPrefix) }
    }

    private func handleMessageEnd(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        guard let message = event.message else { return }
        finalizeCompletedMessage(message, rawLine: rawLine, sessionID: sessionID)
    }

    private func finalizeCompletedMessage(_ message: JSONValue, rawLine: String, sessionID: UUID) {
        let text = extractText(from: message)
        let role = message["role"]?.stringValue ?? "assistant"
        if role == "assistant" {
            rememberPiMessage(message, sessionID: sessionID)
            applyAssistantUsage(message["usage"], sessionID: sessionID)
            streamFlushTasksBySessionID[sessionID]?.cancel()
            streamFlushTasksBySessionID[sessionID] = nil
            let assistantEntryID = assistantEntryIDsBySessionID[sessionID] ?? UUID()
            let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID] ?? UUID()
            let thinkingBeforeID = assistantEntryIDsBySessionID[sessionID]
            // The text accumulated from streaming deltas — what the user actually
            // saw. Capture it before clearing the buffer so we can fall back to it
            // below when the end event omits the body.
            let streamedText = assistantTextBySessionID[sessionID] ?? ""
            let streamedThinking = thinkingTextBySessionID[sessionID] ?? ""
            assistantEntryIDsBySessionID[sessionID] = nil
            assistantTextBySessionID[sessionID] = nil
            thinkingEntryIDsBySessionID[sessionID] = nil
            thinkingTextBySessionID[sessionID] = nil
            let visibleText = extractAssistantText(from: message)
            // Always resolve thinking: message content blocks first, then the
            // streamed thinking_delta buffer. Previously thinking was only
            // persisted when the assistant body was empty, so normal turns lost
            // reasoning on message_end (and reload).
            var thinkingText = extractAssistantThinking(from: message)
            if thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                thinkingText = TextSanitizer.sanitizeThinking(streamedThinking)
            }
            if !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.upsert(
                    .init(
                        id: thinkingEntryID,
                        sessionID: sessionID,
                        role: .thinking,
                        title: LanguageStore.shared.t("run.thinking"),
                        text: thinkingText,
                        rawJSON: nil
                    ),
                    before: thinkingBeforeID,
                    revisionPolicy: .immediateForSelectedSession
                )
            }
            RPCDebugLog.log("  finalize assistant: entryID=\(assistantEntryID.uuidString.prefix(8)) visibleLen=\(visibleText.count) streamedLen=\(streamedText.count) thinkingLen=\(thinkingText.count) dedup=\(visibleText.isEmpty ? false : recentAssistantEntryExists(with: visibleText, sessionID: sessionID, excluding: assistantEntryID)) recentAssistantCount=\(store.transcript(for: sessionID).suffix(8).filter { $0.role == .assistant }.count)")
            if !visibleText.isEmpty {
                // Exclude the placeholder we're finalizing: streaming flushes already
                // wrote the full text into that same entry id (persist:false, so it
                // never reached disk). Without the exclusion the dedup matches the
                // entry against itself and returns early, so the persist:true write
                // below never runs and only the empty turn-start placeholder survives
                // on disk — the response vanishes on reload. The dedup still catches
                // duplicate finalizes (message_end + turn_end + agent_end), which
                // arrive with a fresh entry id once this one is nilled out above.
                guard !recentAssistantEntryExists(with: visibleText, sessionID: sessionID, excluding: assistantEntryID) else {
                    if !activeAgentRunSessionIDs.contains(sessionID) {
                        scheduleIdleConfirmation(sessionID: sessionID)
                    }
                    return
                }
                store.upsert(.init(id: assistantEntryID, sessionID: sessionID, role: .assistant, title: LanguageStore.shared.t("run.assistant"), text: visibleText, rawJSON: nil), revisionPolicy: .immediateForSelectedSession)
            } else if !streamedText.isEmpty {
                // The end event carried no assistant body. Some model backends
                // stream the response only through deltas and omit the text from the
                // final message payload (observed with non-Pi providers routed via
                // opencode). Without this, the turn-start placeholder — persisted
                // empty — is all that reaches disk, and the response the user watched
                // stream vanishes on reload. Persist the streamed buffer on the SAME
                // entry id (updates the in-memory streamed entry in place, so no
                // duplicate).
                let answer = TextSanitizer.sanitizeAnswer(streamedText)
                store.upsert(.init(id: assistantEntryID, sessionID: sessionID, role: .assistant, title: LanguageStore.shared.t("run.assistant"), text: answer, rawJSON: nil), revisionPolicy: .immediateForSelectedSession)
            } else if let errorText = assistantErrorMessage(from: message) {
                // Pi aborted the turn (provider/auth failure, etc.). The final
                // assistant message carries stopReason:"error" + errorMessage with
                // empty content, and Pi emits no separate `error` RPC event — without
                // this branch the empty turn-start placeholder is all that survives and
                // the failure is invisible. Convert the placeholder in place into an
                // error entry so the transcript shows what went wrong.
                //
                // Pi can deliver the same final message on message_end, turn_end AND
                // agent_end; the first run nils out the assistant entry id, so without
                // this dedup each subsequent run appends another identical error row.
                guard !recentErrorEntryExists(with: errorText, sessionID: sessionID) else {
                    if !activeAgentRunSessionIDs.contains(sessionID) {
                        scheduleIdleConfirmation(sessionID: sessionID)
                    }
                    return
                }
                store.upsert(.init(id: assistantEntryID, sessionID: sessionID, role: .error, title: LanguageStore.shared.t("run.modelError"), text: errorText, rawJSON: rawLine), revisionPolicy: .immediateForSelectedSession)
            }
            // `message_end` only completes one message. Pi may still continue the same
            // run with tools, compaction, retries, follow-ups, or another turn. Wait for
            // `agent_end` (or a non-active get_state outside an agent run) before idling.
        } else if role == "user" {
            // Pi echoes user messages back over RPC. The app already records the submitted prompt.
            return
        } else if role == "toolResult" {
            if !text.isEmpty {
                store.append(.init(sessionID: sessionID, role: .raw, title: role, text: text, rawJSON: rawLine))
            }
            // A tool result ends only the tool message; the agent may still perform a
            // follow-up model turn. `agent_end` is the authoritative completion signal.
        } else if !text.isEmpty {
            store.append(.init(sessionID: sessionID, role: .raw, title: role, text: text, rawJSON: rawLine))
        }
    }

    private func rememberPiMessage(_ message: JSONValue, sessionID: UUID) {
        let key = message["id"]?.stringValue ?? message.compactDescription
        var messages = piMessagesBySessionID[sessionID] ?? []
        guard !messages.contains(where: { ($0["id"]?.stringValue ?? $0.compactDescription) == key }) else { return }
        messages.append(message)
        piMessagesBySessionID[sessionID] = messages
    }

    private func applyVerifiedCostBreakdownIfPossible(sessionID: UUID, messages: [JSONValue]) {
        store.updateSession(sessionID) { record in
            record.costBreakdown = PiAgentUsageCostBreakdown.verifiedAssistantCategoryCosts(
                from: messages,
                statsTotalCost: record.cost
            )
        }
    }

    private func applyAssistantUsage(_ usage: JSONValue?, sessionID: UUID) {
        guard let usage else { return }
        store.updateSession(sessionID) { record in
            if let v = usage["input"]?.flexibleNumber { record.inputTokens = Int(v) }
            if let v = usage["output"]?.flexibleNumber { record.outputTokens = Int(v) }
            if let v = usage["cacheRead"]?.flexibleNumber { record.cacheReadTokens = Int(v) }
            if let v = usage["cacheWrite"]?.flexibleNumber { record.cacheWriteTokens = Int(v) }
            if let v = usage["totalTokens"]?.flexibleNumber ?? usage["total"]?.flexibleNumber { record.totalTokens = Int(v) }
            if PiAgentUsageCostBreakdown.from(usage["cost"]) != nil {
                record.costBreakdown = nil
            }
        }
    }

    private func recentAssistantEntryExists(with text: String, sessionID: UUID, excluding excludedID: UUID? = nil) -> Bool {
        store.transcript(for: sessionID)
            .reversed()
            .prefix(8)
            .contains { $0.role == .assistant && $0.id != excludedID && $0.text == text }
    }

    private func recentErrorEntryExists(with text: String, sessionID: UUID) -> Bool {
        store.transcript(for: sessionID)
            .reversed()
            .prefix(8)
            .contains { $0.role == .error && $0.text == text }
    }

    /// Repairs a non-live session's transcript from Pi's session JSONL when the
    /// session is opened. Opening a session does not relaunch Pi (so `get_messages`
    /// never fires), which is why answers that never reached our local store — a
    /// turn that finalized empty, or a transcript that was never persisted at all —
    /// would otherwise stay missing on view. Pi's session file is the source of
    /// truth; we read it off the main thread and apply the same reconciliation the
    /// live `get_messages` path uses. Runs at most once per session per launch and
    /// only when there is something to repair.
    func rehydrateTranscriptFromSessionFileIfNeeded(_ session: PiAgentSessionRecord) {
        let sessionID = session.id
        RPCDebugLog.log("REHYDRATE check session=\(sessionID.uuidString.prefix(8)) title=\(session.title) live=\(clientsBySessionID[sessionID] != nil) already=\(rehydratedFromDiskSessionIDs.contains(sessionID)) piFile=\(session.piSessionFile ?? "nil")")
        guard clientsBySessionID[sessionID] == nil else { return }          // live session owns its transcript
        guard !rehydratedFromDiskSessionIDs.contains(sessionID) else { return }
        guard let path = session.piSessionFile, !path.isEmpty else { return }
        let transcript = store.transcript(for: sessionID)
        let assistants = transcript.filter { $0.role == .assistant }
        let needsBackfill = !assistants.isEmpty && assistants.contains { $0.text.isEmpty }
        let needsBuild = transcript.isEmpty
        let needsCostAggregation = session.cost != nil
        RPCDebugLog.log("REHYDRATE decision session=\(sessionID.uuidString.prefix(8)) entries=\(transcript.count) assistants=\(assistants.count) emptyAssistants=\(assistants.filter { $0.text.isEmpty }.count) needsBackfill=\(needsBackfill) needsBuild=\(needsBuild) needsCostAggregation=\(needsCostAggregation)")
        guard needsBackfill || needsBuild || needsCostAggregation else { return }
        rehydratedFromDiskSessionIDs.insert(sessionID)
        Task { [weak self] in
            let messages = await Task.detached { Self.parsePiSessionMessages(at: path) }.value
            RPCDebugLog.log("REHYDRATE parsed session=\(sessionID.uuidString.prefix(8)) piMessages=\(messages.count)")
            await MainActor.run {
                guard let self else { return }
                self.piMessagesBySessionID[sessionID] = messages
                self.applyVerifiedCostBreakdownIfPossible(sessionID: sessionID, messages: messages)
                if needsBackfill || needsBuild {
                    self.applyRehydratedMessages(messages, sessionID: sessionID)
                }
            }
        }
    }

    /// Reconciles Pi's authoritative messages into the local transcript. Shared by
    /// the live `get_messages` response and the on-open disk read.
    ///
    /// - Backfill: when the transcript already has assistant entries, fill any that
    ///   are empty with Pi's answer text and leave everything else (thinking, tools,
    ///   status cards like "Memory Recalled") untouched. Pi emits one assistant
    ///   message per assistant turn and the runner creates one assistant entry per
    ///   turn, so the two lists align positionally; if the counts differ (history
    ///   trimmed by compaction/fork) we skip rather than risk writing the wrong text.
    /// - Build: when there is no local transcript at all, reconstruct one from Pi's
    ///   messages so the conversation is visible.
    private func applyRehydratedMessages(_ piMessages: [JSONValue], sessionID: UUID) {
        guard !piMessages.isEmpty else { return }
        let transcript = store.transcript(for: sessionID)

        if transcript.isEmpty {
            var built = 0
            // Collected forward as we walk: an `mcp` toolCall's args (the server/tool
            // address) keyed by id, so the later toolResult message can re-attach them.
            var argsByToolCallId: [String: JSONValue] = [:]
            for message in piMessages {
                if (message["role"]?.stringValue ?? "") == "assistant",
                   case let .array(blocks) = message["content"] {
                    for block in blocks where block["type"]?.stringValue == "toolCall" {
                        if let id = block["toolCallId"]?.stringValue ?? block["id"]?.stringValue,
                           let args = block["arguments"] {
                            argsByToolCallId[id] = args
                        }
                    }
                }
                for entry in transcriptEntries(rehydrating: message, sessionID: sessionID, argsByToolCallId: argsByToolCallId) {
                    store.append(entry)
                    built += 1
                }
            }
            RPCDebugLog.log("REHYDRATE build session=\(sessionID.uuidString.prefix(8)) appended=\(built) entries from \(piMessages.count) messages")
            return
        }

        let piAssistants = piMessages.filter { ($0["role"]?.stringValue ?? "") == "assistant" }
        let assistantEntryIndices = transcript.indices.filter { transcript[$0].role == .assistant }
        RPCDebugLog.log("REHYDRATE backfill session=\(sessionID.uuidString.prefix(8)) entryAssistants=\(assistantEntryIndices.count) piAssistants=\(piAssistants.count) aligned=\(assistantEntryIndices.count == piAssistants.count)")
        guard assistantEntryIndices.count == piAssistants.count else { return }
        var filled = 0
        for (slot, entryIndex) in assistantEntryIndices.enumerated() {
            let entry = transcript[entryIndex]
            guard entry.text.isEmpty else { continue }
            let recovered = extractAssistantText(from: piAssistants[slot])
            guard !recovered.isEmpty else { continue }
            store.updateEntry(entry.id, in: sessionID) { $0.text = recovered }
            filled += 1
            RPCDebugLog.log("REHYDRATE filled slot=\(slot) entryID=\(entry.id.uuidString.prefix(8)) len=\(recovered.count) preview=\(recovered.prefix(40))")
        }
        RPCDebugLog.log("REHYDRATE backfill done session=\(sessionID.uuidString.prefix(8)) filled=\(filled)")
    }

    /// Maps a single Pi session message into the transcript entries used to rebuild
    /// a missing transcript. Mirrors how the live stream produces entries.
    private func transcriptEntries(
        rehydrating message: JSONValue,
        sessionID: UUID,
        argsByToolCallId: [String: JSONValue] = [:]
    ) -> [PiAgentTranscriptEntry] {
        switch message["role"]?.stringValue ?? "" {
        case "user":
            let text = extractText(from: message)
            // Keep extension slash commands out of Deck history on rehydrate too.
            if text.isEmpty || Self.isEphemeralSlashCommandMessage(text: text, images: [], pasteAttachments: []) {
                return []
            }
            return [.init(sessionID: sessionID, role: .user, title: LanguageStore.shared.t("run.you"), text: text)]
        case "assistant":
            var entries: [PiAgentTranscriptEntry] = []
            let thinking = extractAssistantThinking(from: message)
            if !thinking.isEmpty {
                entries.append(.init(sessionID: sessionID, role: .thinking, title: LanguageStore.shared.t("run.thinking"), text: thinking))
            }
            let text = extractAssistantText(from: message)
            if !text.isEmpty {
                entries.append(.init(sessionID: sessionID, role: .assistant, title: LanguageStore.shared.t("run.assistant"), text: text))
            }
            return entries
        case "toolResult", "bashExecution":
            let text = extractText(from: message)
            let name = message["toolName"]?.stringValue ?? "Tool"
            guard !text.isEmpty else { return [] }
            // The live stream re-attaches a tool call's args to its entry so the MCP
            // card can read the `server/tool` address. On reload the result lives in a
            // separate message from the `toolCall` that carried the args, so pair them
            // back by id — scoped to `mcp` so the tuned web/diff reload rows are untouched.
            var rawJSON: String?
            if name == "mcp", let id = message["toolCallId"]?.stringValue, let args = argsByToolCallId[id] {
                rawJSON = Self.rehydratedToolRawJSON(toolName: name, args: args)
            }
            return [.init(sessionID: sessionID, role: .tool, title: name, text: text, rawJSON: rawJSON)]
        default:
            return []
        }
    }

    /// Synthesizes a minimal tool-end rawJSON carrying the call's `args`, for a
    /// rehydrated tool entry whose original RPC line is gone.
    private static func rehydratedToolRawJSON(toolName: String, args: JSONValue) -> String? {
        guard let argsData = try? JSONEncoder().encode(args),
              let argsObject = try? JSONSerialization.jsonObject(with: argsData) else { return nil }
        let object: [String: Any] = ["type": "tool_execution_end", "toolName": toolName, "args": argsObject]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a Pi session `.jsonl` file off the main thread and returns the message
    /// objects (the `message` payload of each `message` line), in order. Lines
    /// without a `message.role` (session/model metadata) are ignored.
    private nonisolated static func parsePiSessionMessages(at path: String) -> [JSONValue] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var messages: [JSONValue] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? decoder.decode(JSONValue.self, from: lineData),
                  let message = object["message"],
                  message["role"]?.stringValue != nil else { continue }
            messages.append(message)
        }
        return messages
    }

    private func finalAssistantMessage(from event: PiAgentRPCEvent) -> JSONValue? {
        if let message = event.message,
           (message["role"]?.stringValue ?? "assistant") == "assistant" {
            return message
        }
        guard case let .array(messages) = event.messages else { return nil }
        return messages.last { ($0["role"]?.stringValue ?? "") == "assistant" }
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
            store.setProcessingActivity(
                .runningTool(name: toolName, detail: toolActivityDetail(toolName: toolName, args: event.args)),
                for: sessionID
            )
            if let args = event.args { toolStartArgsByCallID[toolKey] = args }
            text = event.args?.compactDescription ?? "Starting…"
        case "tool_execution_update":
            let partialText = extractText(from: event.partialResult ?? .null)
            if toolName == "mcp" {
                text = Self.mcpSafeResultText(event.partialResult) ?? (partialText.isEmpty ? "MCP result updating…" : partialText)
            } else {
                text = partialText.isEmpty ? (event.partialResult?.compactDescription ?? "Running…") : partialText
            }
        case "tool_execution_end":
            // Also close out on tool end — by the time the next thinking_delta arrives,
            // we want a brand-new thinking entry whose timestamp is after this tool's.
            finalizeStreamingThinking(sessionID: sessionID)
            // The tool has finished; the indicator must stop saying "Running <tool>"
            // while Pi spends the next few seconds on its follow-up model call.
            store.setProcessingActivity(.awaitingModel, for: sessionID)
            let resultText = extractText(from: event.result ?? .null)
            if toolName == "mcp" {
                // Never construct a transcript fallback from an image block's
                // compactDescription: it includes its base64 data.
                text = Self.mcpSafeResultText(event.result) ?? (resultText.isEmpty ? "MCP returned a result." : resultText)
            } else {
                text = resultText.isEmpty ? (event.result?.compactDescription ?? "Completed.") : resultText
            }
            toolEntryIDsByCallID[toolKey] = nil
        default:
            text = rawLine
        }
        // Keep the call's args on the entry across its lifetime: the update/end events
        // drop top-level `args`, but the stored entry must still expose it (the MCP
        // card reads `args.tool`). Re-attach the cached start args when the current
        // event lacks them, so the final rawJSON carries both args and result.
        var effectiveRawJSON = rawLine
        if event.args == nil, let cachedArgs = toolStartArgsByCallID[toolKey],
           let merged = Self.rawJSON(rawLine, attaching: cachedArgs) {
            effectiveRawJSON = merged
        }
        if event.type == "tool_execution_end" { toolStartArgsByCallID[toolKey] = nil }
        store.upsert(.init(id: entryID, sessionID: sessionID, role: event.isError == true ? .error : .tool, title: title, text: text, rawJSON: effectiveRawJSON))
    }

    private static func mcpSafeResultText(_ result: JSONValue?) -> String? {
        guard case let .array(blocks)? = result?["content"] else { return nil }
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        if !text.isEmpty { return text }
        return blocks.contains { $0["type"]?.stringValue == "image" } ? "MCP returned an image." : nil
    }

    /// Returns `rawLine` (a JSON object string) with the tool-call `args` re-attached
    /// under the top-level `args` key. Used so update/end tool events keep the call's
    /// arguments that only the start event carried. Returns nil if `rawLine` isn't a
    /// JSON object or the args can't be encoded (caller falls back to `rawLine`).
    private static func rawJSON(_ rawLine: String, attaching args: JSONValue) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(rawLine.utf8))) as? [String: Any],
              let argsData = try? JSONEncoder().encode(args),
              let argsObject = try? JSONSerialization.jsonObject(with: argsData) else { return nil }
        object["args"] = argsObject
        guard let mergedData = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: mergedData, as: UTF8.self)
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
        let display = TextSanitizer.sanitizeThinking(thinkingText)
        if !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.upsert(.init(
                id: thinkingEntryID,
                sessionID: sessionID,
                role: .thinking,
                title: LanguageStore.shared.t("run.thinking"),
                text: display,
                rawJSON: nil
            ), before: assistantEntryIDsBySessionID[sessionID], persist: false)
        }
        thinkingEntryIDsBySessionID[sessionID] = nil
        thinkingTextBySessionID[sessionID] = nil
    }

    /// Pulls the one meaningful argument out of a tool call — the file it
    /// touches, the command it runs, the query it searches — so the processing
    /// indicator can say "Editing PiAgentViews.swift" instead of "Running edit".
    /// Returns `nil` for tools with no concise target.
    private func toolActivityDetail(toolName: String, args: JSONValue?) -> String? {
        guard let args else { return nil }
        switch toolName {
        case "read", "edit", "write":
            guard let path = args["path"]?.stringValue else { return nil }
            let component = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            return component.isEmpty ? nil : component
        case "bash":
            return condensedSingleLine(args["command"]?.stringValue)
        case "web_search", "code_search":
            return condensedSingleLine(args["query"]?.stringValue)
        case "mcp":
            guard let rawTool = args["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTool.isEmpty,
                  let address = MCPConnectionManager.resolveAddress(rawTool, serverHint: args["server"]?.stringValue)
            else { return nil }
            return "\(address.server)/\(address.tool)"
        default:
            return nil
        }
    }

    /// Collapses a possibly multi-line argument to its first non-empty line so
    /// it reads cleanly in the single-line indicator bar.
    private func condensedSingleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let condensed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return condensed.isEmpty ? nil : condensed
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
        store.upsert(.init(id: entryID, sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.compaction"), text: text, rawJSON: rawLine))
        if event.type == "compaction_end" {
#if DEBUG
            let willRetry = event.willRetry == true
            Self.logger.info("Compaction complete reason=\(reason, privacy: .public) willRetry=\(willRetry, privacy: .public)")
            // Open a short window so we can see whether Pi emits a continuation turn next.
            postCompactionLogCountBySessionID[sessionID] = 12
#endif
            clientsBySessionID[sessionID]?.getState()
            clientsBySessionID[sessionID]?.getSessionStats()
        }
    }

    private func handleRetry(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let text = event.errorMessage ?? event.data?.compactDescription ?? rawLine
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.retry"), text: text, rawJSON: rawLine))
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
            case "mcp":
                handleMCPBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "memory_write":
                handleMemoryWriteBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "memory_mark_stale":
                handleMemoryMarkStaleBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            case "memory_search":
                handleMemorySearchBridgeRequest(event, requestID: requestID, rawLine: rawLine, sessionID: sessionID)
            default:
                clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) does not support bridge request \(bridgeName).")
                store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Unsupported bridge request \(bridgeName).", rawJSON: rawLine))
            }
            return
        }

        if let requestMethod = PiAgentUIRequest.Method(rawValue: method), let requestID = event.id {
            if requestMethod == .input, let pendingFreeform = pendingFreeformResponsesBySessionID.removeValue(forKey: sessionID) {
                clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: pendingFreeform)
                store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.inputSent"), text: "Custom response sent.", rawJSON: rawLine))
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
            store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.inputNeeded"), text: title, rawJSON: rawLine))
            return
        }

        // Fire-and-forget extension chrome → soft in-timeline system notices
        // (Claude-style `[tag]` cards). Not chat bubbles; still session-local history.
        switch method {
        case "notify":
            appendExtensionSystemNotice(event, rawLine: rawLine, sessionID: sessionID, kind: .notify)
        case "setStatus":
            appendExtensionSystemNotice(event, rawLine: rawLine, sessionID: sessionID, kind: .status)
        case "setWidget":
            appendExtensionSystemNotice(event, rawLine: rawLine, sessionID: sessionID, kind: .widget)
        case "setTitle", "set_editor_text":
            // Title/editor chrome is not modeled in the transcript.
            break
        default:
            break
        }
    }

    private enum ExtensionSystemNoticeKind {
        case notify
        case status
        case widget
    }

    /// Append a soft system-notice status row for extension UI chrome.
    ///
    /// - Parameters:
    ///   - event: Decoded extension_ui_request. Required.
    ///   - rawLine: Raw JSONL fallback for message parse. Required.
    ///   - sessionID: Owning Deck session. Required.
    ///   - kind: notify / setStatus / setWidget. Required.
    private func appendExtensionSystemNotice(
        _ event: PiAgentRPCEvent,
        rawLine: String,
        sessionID: UUID,
        kind: ExtensionSystemNoticeKind
    ) {
        let body: String
        let title: String
        switch kind {
        case .notify:
            let rawMessage = extensionNotifyMessage(from: event, rawLine: rawLine)
            body = TextSanitizer.sanitizeAnswer(rawMessage ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let levelRaw = event.notifyType
                ?? extensionUIString("notifyType", from: event)
                ?? extensionNotifyTopLevelString("notifyType", from: rawLine)
            switch (levelRaw ?? "").lowercased() {
            case "warning", "warn": title = "Notify Warning"
            case "error", "danger", "fail", "failure": title = "Notify Error"
            default: title = "Notify"
            }
        case .status:
            let key = event.statusKey
                ?? extensionUIString("statusKey", from: event)
                ?? extensionUIString("key", from: event)
                ?? "status"
            let text = event.statusText
                ?? extensionUIString("statusText", from: event)
                ?? extensionUIString("text", from: event)
                ?? extensionNotifyMessage(from: event, rawLine: rawLine)
                ?? ""
            let sanitized = TextSanitizer.sanitizeAnswer(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = sanitized.isEmpty ? "" : "[\(key)]\n\(sanitized)"
            title = "Extension Status"
        case .widget:
            let key = event.widgetKey
                ?? extensionUIString("widgetKey", from: event)
                ?? extensionUIString("key", from: event)
                ?? "widget"
            let lines = extensionUIStringList(event.widgetLines)
                ?? extensionUIStringList(event.data?["widgetLines"])
                ?? extensionUIStringList(event.data?["lines"])
                ?? extensionUIStringList(event.message?["widgetLines"])
                ?? []
            let joined = lines
                .map { TextSanitizer.sanitizeAnswer($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            body = joined.isEmpty ? "" : "[\(key)]\n\(joined)"
            title = "Extension Widget"
        }
        guard !body.isEmpty else { return }
        // Extension hosts often re-emit the same notify/status on resume or
        // double RPC delivery — collapse consecutive identical soft cards.
        if let last = store.transcript(for: sessionID).last,
           last.role == .status,
           last.title == title,
           last.text == body {
            return
        }
        store.append(.init(
            sessionID: sessionID,
            role: .status,
            title: title,
            text: body,
            rawJSON: rawLine
        ))
    }

    /// Resolve notify message from decoded event, nested keys, then raw JSON.
    ///
    /// - Parameters:
    ///   - event: Decoded RPC event. Required.
    ///   - rawLine: Raw JSONL line. Required.
    /// - Returns: Message when present.
    private func extensionNotifyMessage(from event: PiAgentRPCEvent, rawLine: String) -> String? {
        if let message = event.message?.stringValue,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let message = extensionUIString("message", from: event) {
            return message
        }
        if let message = extensionNotifyTopLevelString("message", from: rawLine),
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        // Avoid compactDescription of non-string message objects (noisy key dumps).
        return nil
    }

    /// Read a top-level string field from a raw extension_ui_request JSON line.
    ///
    /// - Parameters:
    ///   - key: JSON object key. Required.
    ///   - rawLine: Raw JSONL. Required.
    /// - Returns: String value when present.
    private func extensionNotifyTopLevelString(_ key: String, from rawLine: String) -> String? {
        guard let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
        return nil
    }

    private func handleMemoryMarkStaleBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryStaleBridgeRequest.self, from: data) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the stale memory request.")
            store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse stale memory request.", rawJSON: rawLine))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemoryMarkStale?(sessionID, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMemorySearchBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemorySearchBridgeRequest.self, from: data) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the memory search request.")
            store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse memory search request.", rawJSON: rawLine))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemorySearch?(sessionID, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMemoryWriteBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(AgentMemoryWriteBridgeRequest.self, from: data) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the memory write request.")
            store.append(.init(sessionID: sessionID, role: .error, title: "\(AppBrand.displayName) Bridge Error", text: "Could not parse memory write request.", rawJSON: rawLine))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onMemoryWrite?(sessionID, request) ?? "\(AppBrand.displayName) memory is not available."
            self.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
        }
    }

    private func handleMCPBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiMCPBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the mcp request.")
            return
        }
        guard let onMCPBridgeRequest else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName)'s MCP bridge is not available.")
            return
        }
        onMCPBridgeRequest(sessionID, request) { [weak self] result in
            Task { @MainActor in
                self?.clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
            }
        }
    }

    private func handleManagedSubagentBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiManagedSubagentBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the managed_subagent request.")
            return
        }
        guard let onManagedSubagentRequest else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName)'s Deck agent bridge is not available.")
            return
        }
        // Surface the request in the parent transcript (the UI maps this title to a
        // "Starting Deck agent" status), mirroring the supervisor/ask_user bridges.
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.deckAgentRequested"), text: "\(request.agent): \(request.task)", rawJSON: rawLine))
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
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName)'s Deck agent parallel bridge is not available.")
            return
        }
        // Surface the parallel request in the parent transcript (UI maps this title to
        // a "Starting parallel run" status).
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.parallelDeckAgentsRequested"), text: request.tasks.map(\.agent).joined(separator: ", "), rawJSON: rawLine))
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
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.supervisorResponseRouted"), text: request.requestID, rawJSON: rawLine))
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
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.systemPromptCaptured"), text: "Captured \(request.systemPrompt.count) characters from Pi runtime.", rawJSON: rawLine))
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
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.inputNeeded"), text: request.question, rawJSON: rawLine))
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

    /// Flatten a JSON string or string-array into display lines for setWidget.
    ///
    /// - Parameter value: Optional JSON value from RPC. Optional.
    /// - Returns: Non-empty string list when parseable.
    private func extensionUIStringList(_ value: JSONValue?) -> [String]? {
        guard let value else { return nil }
        switch value {
        case .string(let s):
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.isEmpty ? nil : lines
        case .array(let items):
            let lines = items.compactMap { item -> String? in
                switch item {
                case .string(let s): return s
                default: return item.stringValue
                }
            }
            return lines.isEmpty ? nil : lines
        default:
            if let s = value.stringValue, !s.isEmpty { return [s] }
            return nil
        }
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
                return .init(sessionID: sessionID, role: .assistant, title: LanguageStore.shared.t("run.assistant"), text: text.isEmpty ? type : text, rawJSON: nil)
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
            case let .string(value):
                return TextSanitizer.sanitizeAnswer(value)
            case let .array(blocks):
                let joined = blocks.compactMap { block -> String? in
                    let blockType = block["type"]?.stringValue
                    if blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" {
                        return block["text"]?.stringValue
                    }
                    return nil
                }.joined(separator: "\n")
                return TextSanitizer.sanitizeAnswer(joined)
            default:
                // Non-text assistant content is usually tool metadata. Do not turn it into a Pi answer.
                return ""
            }
        }
        return TextSanitizer.sanitizeAnswer(message["output"]?.stringValue ?? "")
    }

    /// The model/provider error carried on a final assistant message that
    /// produced no text. Pi puts the failure on the message itself
    /// (`stopReason: "error"` + `errorMessage`) rather than emitting a separate
    /// `error` RPC event, so this is the only place a fatal turn error surfaces.
    private func assistantErrorMessage(from message: JSONValue) -> String? {
        if let raw = message["errorMessage"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if message["stopReason"]?.stringValue == "error" {
            return "The model provider returned an error."
        }
        return nil
    }

    private func extractAssistantThinking(from message: JSONValue) -> String {
        guard let content = message["content"] else { return "" }
        guard case let .array(blocks) = content else { return "" }
        let joined = blocks.compactMap { block -> String? in
            let blockType = block["type"]?.stringValue
            guard blockType == "thinking" || blockType == "reasoning" else { return nil }
            return block["thinking"]?.stringValue ?? block["text"]?.stringValue
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
        return TextSanitizer.sanitizeThinking(joined)
    }

    private func handleTermination(exitCode: Int32, sessionID: UUID, clientRunID: UUID) {
        if parkingClientRunIDsBySessionID[sessionID] == clientRunID {
            parkingClientRunIDsBySessionID[sessionID] = nil
            clearStreamingState(sessionID: sessionID)
            if clientsBySessionID[sessionID] == nil {
                mark(sessionID, status: .idle, error: nil)
            }
            runAfterFinishHookIfNeeded(sessionID: sessionID, clientRunID: clientRunID, status: .idle, exitCode: exitCode)
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
            runAfterFinishHookIfNeeded(sessionID: sessionID, clientRunID: clientRunID, status: .stopped, exitCode: exitCode)
            return
        }

        guard clientRunIDsBySessionID[sessionID] == clientRunID else { return }
        clearStreamingState(sessionID: sessionID)
        clientRunIDsBySessionID[sessionID] = nil
        clientsBySessionID[sessionID] = nil
        let status: PiAgentRunStatus = exitCode == 0 ? .completed : .stopped
        mark(sessionID, status: status, error: nil)
        store.append(.init(sessionID: sessionID, role: .status, title: "Process Ended", text: "Pi Agent exited with code \(exitCode)."))
        runAfterFinishHookIfNeeded(sessionID: sessionID, clientRunID: clientRunID, status: status, exitCode: exitCode)
        onSessionProcessTerminated?(sessionID)
        onTurnFinished?(sessionID)
    }

    private func runAfterFinishHookIfNeeded(sessionID: UUID, clientRunID: UUID, status: PiAgentRunStatus, exitCode: Int32?) {
        guard afterFinishHookRunIDs.insert(clientRunID).inserted else { return }
        AgentDeckBuiltinHooks.afterFinish(.init(sessionID: sessionID, status: status, exitCode: exitCode))
    }

    private func mark(_ sessionID: UUID, status: PiAgentRunStatus, error: String?) {
        RPCDebugLog.log("DEBUG-STOP mark status=\(String(describing: status)) session=\(sessionID.uuidString)")
        cancelPendingIdle(for: sessionID)
        store.updateSession(sessionID) { record in
            record.status = status
            record.lastError = error
            if !status.isActive {
                record.isCompacting = false
            }
        }
        if !status.isActive {
            store.setProcessingActivity(nil, for: sessionID)
        }
    }
}
