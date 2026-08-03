import Foundation
import os

// MARK: - Launch, idle parking, launch config

@MainActor
extension PiAgentRunnerService {
    func start(
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

    func isCurrentLaunch(sessionID: UUID, generation: UUID) -> Bool {
        launchGenerationsBySessionID[sessionID] == generation
    }

    func scheduleLaunchWatchdog(sessionID: UUID, generation: UUID) {
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

    func cancelLaunchWatchdog(sessionID: UUID) {
        launchWatchdogTasksBySessionID.removeValue(forKey: sessionID)?.cancel()
    }

    func drainPendingStartupInputs(sessionID: UUID, client: PiRPCClient) {
        let inputs = pendingStartupInputsBySessionID.removeValue(forKey: sessionID) ?? []
        for input in inputs {
            client.prompt(input.message, images: input.images, streamingBehavior: "steer")
        }
    }

    func discardPendingStartupInputs(sessionID: UUID, title: String, text: String) {
        guard let inputs = pendingStartupInputsBySessionID.removeValue(forKey: sessionID), !inputs.isEmpty else { return }
        store.append(.init(sessionID: sessionID, role: .status, title: title, text: "\(text). \(inputs.count) \(inputs.count == 1 ? "message was" : "messages were") not delivered."))
    }

    func migrateLegacyGeneralChatScratchFolderIfNeeded(for session: PiAgentSessionRecord, targetURL: URL) {
        let legacyURL = session.legacyNoProjectLaunchWorkingDirectory
        let fileManager = FileManager.default
        guard legacyURL.standardizedFileURL.path != targetURL.standardizedFileURL.path,
              fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: targetURL.path) else { return }
        try? fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacyURL, to: targetURL)
    }

    func launchConfiguration(for session: PiAgentSessionRecord) -> (provider: String?, model: String?, thinkingLevel: String?) {
        launchConfiguration(for: session, boundAgent: nil)
    }

    /// Resolves the provider/model/thinking-level triple Pi should be launched with.
    /// User overrides win first; otherwise the session's last-known model is used.
    /// For agent-bound sessions, when no user override is set, the agent's
    /// `resolved.model` / `resolved.thinking` (resolved by `PiSubagentLaunchPlanner`)
    /// becomes the default — letting the agent author dictate the model.
    func launchConfiguration(for session: PiAgentSessionRecord, boundAgent: EffectiveAgentRecord?) -> (provider: String?, model: String?, thinkingLevel: String?) {
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

    func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    func resetIdleParkingDeadlineIfIdle(sessionID: UUID) {
        cancelIdleParking(for: sessionID)
        scheduleIdleParkingIfNeeded(sessionID: sessionID)
    }

    func cancelIdleParking(for sessionID: UUID) {
        cancelPendingIdle(for: sessionID)
        idleParkingTasksBySessionID[sessionID]?.cancel()
        idleParkingTasksBySessionID[sessionID] = nil
    }

    func cancelPendingIdle(for sessionID: UUID) {
        pendingIdleTasksBySessionID[sessionID]?.cancel()
        pendingIdleTasksBySessionID[sessionID] = nil
    }

    func scheduleIdleConfirmation(sessionID: UUID) {
        guard pendingIdleTasksBySessionID[sessionID] == nil else { return }
        pendingIdleTasksBySessionID[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: self?.idleConfirmationDelay ?? .milliseconds(900))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.confirmIdleIfStillEligible(sessionID: sessionID)
            }
        }
    }

    func confirmIdleIfStillEligible(sessionID: UUID) {
        pendingIdleTasksBySessionID[sessionID] = nil
        guard !activeAgentRunSessionIDs.contains(sessionID),
              let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status.isActive,
              store.uiRequestsBySessionID[sessionID] == nil else { return }
        // turn_start seeds assistantText="" (empty placeholder). Only non-empty
        // buffers mean an open stream. Treating "" as blocking left sessions
        // stuck in .running after thinking-only / missing final payload turns.
        let openAssistant = !(assistantTextBySessionID[sessionID] ?? "").isEmpty
        let openThinking = !(thinkingTextBySessionID[sessionID] ?? "").isEmpty
        guard !openAssistant, !openThinking else { return }
        // Drop empty turn_start / thinking placeholders so parking eligibility matches.
        if (assistantTextBySessionID[sessionID] ?? "").isEmpty {
            assistantTextBySessionID[sessionID] = nil
            assistantEntryIDsBySessionID[sessionID] = nil
        }
        if (thinkingTextBySessionID[sessionID] ?? "").isEmpty {
            thinkingTextBySessionID[sessionID] = nil
            thinkingEntryIDsBySessionID[sessionID] = nil
        }
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

    func scheduleIdleParkingIfNeeded(sessionID: UUID) {
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

    func parkIdleSessionIfStillEligible(sessionID: UUID) {
        idleParkingTasksBySessionID[sessionID] = nil
        guard isEligibleForIdleParking(sessionID: sessionID),
              let client = clientsBySessionID.removeValue(forKey: sessionID),
              let clientRunID = clientRunIDsBySessionID.removeValue(forKey: sessionID) else { return }
        parkingClientRunIDsBySessionID[sessionID] = clientRunID
        clearStreamingState(sessionID: sessionID)
        mark(sessionID, status: .idle, error: nil)
        client.stop()
    }

    func isEligibleForIdleParking(sessionID: UUID) -> Bool {
        guard idleParkingTimeout != nil,
              let client = clientsBySessionID[sessionID],
              client.isRunning,
              let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status == .idle,
              session.piSessionFile?.isEmpty == false,
              store.uiRequestsBySessionID[sessionID] == nil else { return false }
        // Empty "" placeholders from turn_start must not block idle parking.
        let openAssistant = !(assistantTextBySessionID[sessionID] ?? "").isEmpty
        let openThinking = !(thinkingTextBySessionID[sessionID] ?? "").isEmpty
        return !openAssistant && !openThinking
    }
}
