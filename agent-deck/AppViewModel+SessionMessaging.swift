import Foundation
import SwiftUI

// MARK: - Session messaging, titles, controls

extension AppViewModel {
    func sendPiAgentMessage(_ text: String, mode: PiAgentInputMode, transcriptText: String? = nil, titleSource: String? = nil, images: [PiAgentImageAttachment] = [], pasteAttachments: [PiAgentPasteAttachment] = [], beforeStart: () -> Void = {}) -> Bool {
        guard let session = piAgentSessionStore.selectedSession else { return false }
        beforeStart()
        enqueuePiAgentMessage(
            text, mode: mode, transcriptText: transcriptText, titleSource: titleSource,
            images: images, pasteAttachments: pasteAttachments,
            session: session
        )
        return true
    }

    func enqueuePiAgentMessage(_ text: String, mode: PiAgentInputMode, transcriptText: String?, titleSource: String?, images: [PiAgentImageAttachment], pasteAttachments: [PiAgentPasteAttachment], session: PiAgentSessionRecord) {
        // Worktree isolation materializes on the first message, reading the
        // global setting at send time. Until then the draft is a pure record,
        // so the user can change their mind (or the setting) freely. The
        // provisioning task is shared per session: a second send racing the
        // first awaits the same task instead of provisioning twice, which
        // would tear down the in-progress worktree (creation clears leftovers
        // at the session's target path).
        if session.status == .draft,
           session.piSessionFile == nil,
           session.worktreePath == nil,
           !piAgentRunner.isRunning(sessionID: session.id),
           appSettings.piAgentSessionsUseWorktree,
           let project = projectByPath[session.projectPath] {
            let provisionTask = worktreeProvisionTasksBySessionID[session.id] ?? Task { @MainActor [weak self] in
                await self?.provisionWorktreeIfEnabled(for: session.id, project: project)
            }
            worktreeProvisionTasksBySessionID[session.id] = provisionTask
            Task { @MainActor [weak self] in
                await provisionTask.value
                guard let self else { return }
                self.worktreeProvisionTasksBySessionID.removeValue(forKey: session.id)
                guard let refreshed = self.piAgentSessionStore.sessions.first(where: { $0.id == session.id }) else { return }
                self.deliverPiAgentMessage(text, mode: mode, transcriptText: transcriptText, titleSource: titleSource, images: images, pasteAttachments: pasteAttachments, session: refreshed)
            }
            return
        }
        deliverPiAgentMessage(text, mode: mode, transcriptText: transcriptText, titleSource: titleSource, images: images, pasteAttachments: pasteAttachments, session: session)
    }


    func deliverPiAgentMessage(_ text: String, mode: PiAgentInputMode, transcriptText: String?, titleSource: String?, images: [PiAgentImageAttachment], pasteAttachments: [PiAgentPasteAttachment], session: PiAgentSessionRecord) {
        let effectiveText = text
        let visibleText = (transcriptText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        let displayOverride = transcriptText
        let omitUserTranscript = PiAgentRunnerService.isEphemeralSlashCommandMessage(
            text: visibleText.isEmpty ? effectiveText : visibleText,
            images: images,
            pasteAttachments: pasteAttachments
        )
        if !omitUserTranscript {
            schedulePiAgentTitleGenerationIfNeeded(
                for: session,
                firstMessage: piAgentTitleGenerationSource(titleSource: titleSource, visibleText: visibleText, effectiveText: effectiveText)
            )
        }
        if !piAgentRunner.isRunning(sessionID: session.id), session.piSessionFile != nil || session.status == .draft {
            piAgentRunner.resume(
                session: session,
                initialPrompt: effectiveText,
                transcriptText: displayOverride,
                images: images,
                pasteAttachments: pasteAttachments,
                recordInTranscript: !omitUserTranscript
            )
            return
        }
        piAgentRunner.send(
            effectiveText,
            mode: mode,
            to: session.id,
            transcriptText: displayOverride,
            images: images,
            pasteAttachments: pasteAttachments,
            recordInTranscript: !omitUserTranscript
        )
    }

    func piAgentTitleGenerationSource(titleSource: String?, visibleText: String, effectiveText: String) -> String {
        if let titleSource, !titleSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return titleSource
        }
        if !visibleText.isEmpty { return visibleText }
        return effectiveText
    }

    func schedulePiAgentTitleUpdateIfNeeded(sessionID: UUID, plan: PiSessionPlanRecord) {
        guard appSettings.autoGeneratePiAgentSessionTitles,
              appSettings.autoUpdatePiAgentSessionTitles,
              !plan.items.isEmpty,
              !piAgentTitleGeneratingSessionIDs.contains(sessionID),
              let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
              !session.title.hasPrefix("Draft ·"),
              !session.isTitleUserEdited,
              let latestUserMessage = piAgentSessionStore.transcript(for: sessionID)
                .filter(\.isProviderBackedUserMessage)
                .max(by: { $0.timestamp < $1.timestamp })?
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !latestUserMessage.isEmpty,
              let model = piAgentTitleGenerationModel() else { return }

        piAgentTitleGeneratingSessionIDs.insert(sessionID)
        let projectURL = session.launchWorkingDirectory
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let environment = EnvRuntimeEnvironment().environment()
        piSessionTitleGenerator.updateTitle(
            currentTitle: session.title,
            latestUserMessage: latestUserMessage,
            planItems: plan.items,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.piAgentTitleGeneratingSessionIDs.remove(sessionID)
            guard case let .success(title) = result,
                  title.caseInsensitiveCompare("KEEP") != .orderedSame else { return }
            guard let current = self.piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
                  !current.title.hasPrefix("Draft ·"),
                  !current.isTitleUserEdited,
                  current.title.caseInsensitiveCompare(title) != .orderedSame else { return }
            withAnimation(.snappy(duration: 0.26)) {
                self.piAgentSessionStore.applyGeneratedTitle(sessionID, title: title)
            }
            self.piAgentRunner.syncSessionName(for: sessionID, force: true)
        }
    }

    func schedulePiAgentTitleGenerationIfNeeded(for session: PiAgentSessionRecord, firstMessage: String) {
        // Auto-title only while the session still has a provisional name
        // (`Draft · …` project drafts or `Chat · …` 1:1 agent chats) and the
        // user has not renamed it. Older logic required an empty transcript so
        // generation ran exactly once on the first send; if the hidden Pi
        // helper failed, the session stayed provisional forever. Retry while
        // still provisional. Agent sessions used to be gated on Draft-only and
        // silently never titled despite the Automations toggle.
        guard appSettings.autoGeneratePiAgentSessionTitles,
              session.isProvisionalAutoTitle,
              !piAgentTitleGeneratingSessionIDs.contains(session.id),
              let model = piAgentTitleGenerationModel() else {
            if appSettings.autoGeneratePiAgentSessionTitles,
               session.isProvisionalAutoTitle,
               piAgentTitleGenerationModel() == nil {
                NSLog("[Pi Deck] session title generation skipped session=%@ reason=no-model", session.id.uuidString)
            }
            return
        }

        let trimmedIncoming = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingUsers = piAgentSessionStore.transcript(for: session.id).filter(\.isProviderBackedUserMessage)
        // Prefer the first real user turn for naming (stable goal); fall back
        // to the message that triggered this send when transcript is empty.
        let sourceMessage: String
        if let firstUser = existingUsers.min(by: { $0.timestamp < $1.timestamp }) {
            let text = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceMessage = text.isEmpty ? trimmedIncoming : text
        } else {
            sourceMessage = trimmedIncoming
        }
        guard !sourceMessage.isEmpty else { return }

        piAgentTitleGeneratingSessionIDs.insert(session.id)
        let projectURL = session.launchWorkingDirectory
        try? FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let environment = EnvRuntimeEnvironment().environment()
        let sessionID = session.id
        let modelLabel = model.identifier
        piSessionTitleGenerator.generateTitle(
            for: sourceMessage,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.piAgentTitleGeneratingSessionIDs.remove(sessionID)
            switch result {
            case let .success(title):
                guard let current = self.piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
                      current.isProvisionalAutoTitle else { return }
                withAnimation(.snappy(duration: 0.26)) {
                    self.piAgentSessionStore.applyGeneratedTitle(sessionID, title: title)
                }
                self.piAgentRunner.syncSessionName(for: sessionID, force: true)
            case let .failure(error):
                // Silent failures made auto-title look "gone". Surface once in
                // the session error slot without interrupting the main chat.
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NSLog("[Pi Deck] session title generation failed session=%@ model=%@ error=%@", sessionID.uuidString, modelLabel, message)
                if let current = self.piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
                   current.isProvisionalAutoTitle {
                    self.piAgentSessionStore.updateSession(sessionID) { record in
                        // Only stamp when empty so we don't clobber a live agent error.
                        if record.lastError == nil || record.lastError?.isEmpty == true {
                            record.lastError = LanguageStore.shared.t("vm.sessionTitleGenFailed", modelLabel, message)
                        }
                    }
                }
            }
        }
    }

    func compactSelectedPiAgentSession(customInstructions: String? = nil) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentRunner.compact(session: session, customInstructions: customInstructions)
    }

    /// Forks the Pi Agent session containing `entry` from that user message via
    /// Pi's native /fork RPC. The user-message index is computed locally and
    /// passed to the runner as a sanity check against Pi's get_fork_messages
    /// reply. Only user-role entries are forkable — the UI gates this — but
    /// guard here anyway so non-UI callers can't misuse it.
    /// Session-wide per-tool call recap (non-web), for the Session resources
    /// popover. Computed on demand from the session's transcript — call it once on
    /// popover appear (not in a SwiftUI body) to avoid recomputing on every
    /// streaming pulse.
    func toolCallRecap(forSessionID sessionID: UUID) -> [PiAgentToolCallRecapItem] {
        NativeToolGroupModel.toolCallRecap(from: piAgentSessionStore.transcript(for: sessionID))
    }

    /// MCP usage for the Session resources popover: every server in scope at launch
    /// (with the tools it advertised), plus the tools actually called this session.
    /// Returns empty when MCP is off or nothing was assigned to the session.
    func mcpSessionRecap(for session: PiAgentSessionRecord) -> [PiAgentMCPSessionRecap] {
        guard appSettings.mcpEnabled else { return [] }
        let scope = assignedMCPServerNames(for: session)
        let usage = NativeToolGroupModel.mcpUsageRecap(from: piAgentSessionStore.transcript(for: session.id))
        guard !scope.isEmpty || !usage.isEmpty else { return [] }

        let advertised = Dictionary(grouping: mcpCatalogSnapshot.filter { scope.contains($0.server) }, by: \.server)
        let usageByServer = Dictionary(uniqueKeysWithValues: usage.map { ($0.server, $0.tools) })
        // Union: in-scope servers (even if never called) and any server actually
        // called (in case it was assigned then later removed from config).
        var serverNames = scope
        serverNames.formUnion(usage.map(\.server))
        return serverNames.sorted().map { server in
            PiAgentMCPSessionRecap(
                server: server,
                advertisedToolCount: advertised[server]?.count ?? 0,
                calledTools: usageByServer[server] ?? []
            )
        }
    }

    func forkPiAgentSession(from entry: PiAgentTranscriptEntry) {
        guard entry.isProviderBackedUserMessage else { return }
        let transcript = piAgentSessionStore.transcript(for: entry.sessionID)
        let userEntries = transcript.filter(\.isProviderBackedUserMessage)
        guard let index = userEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        piAgentRunner.fork(
            sessionID: entry.sessionID,
            userMessageText: entry.text,
            userMessageIndex: index,
            sourceEntryID: entry.id
        )
    }

    /// Re-run the conversation from a user message, in place: the session
    /// rewinds to just before that message (Pi branches its append-only session
    /// file; the dropped turns survive in the parent file on disk) and the
    /// message is resent immediately — same session row, no new fork session.
    /// The resend reuses Pi's recorded text for the message plus the entry's
    /// recorded attachments, so the rerun is exactly the original send.
    func rerunPiAgentSession(from entry: PiAgentTranscriptEntry) {
        guard entry.isProviderBackedUserMessage else { return }
        let transcript = piAgentSessionStore.transcript(for: entry.sessionID)
        let userEntries = transcript.filter(\.isProviderBackedUserMessage)
        guard let index = userEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        let attachments = entry.userAttachments
        piAgentRunner.fork(
            sessionID: entry.sessionID,
            userMessageText: entry.text,
            userMessageIndex: index,
            sourceEntryID: entry.id,
            rerun: .init(
                transcriptText: entry.text,
                images: attachments?.images ?? [],
                pasteAttachments: attachments?.pastes ?? []
            )
        )
    }

    /// Forks the conversation into a fresh 1:1 agent chat. Mirrors the normal
    /// fork UX: the new session shows a fork-origin recap card, seeds the
    /// composer with the forked user-message text, and waits for the user to
    /// review/edit before sending. Unlike `forkPiAgentSession`, this does NOT
    /// use Pi's /fork RPC — the agent's system prompt is incompatible with
    /// the parent's, so transcript replay would be misleading.
    func forkPiAgentSessionAsAgentChat(from entry: PiAgentTranscriptEntry, agent: EffectiveAgentRecord) {
        guard entry.role == .user else { return }
        guard agent.resolved.disabled != true else {
            piAgentRunnerSurfaceError(message: "Agent '\(agent.name)' is disabled.")
            return
        }
        guard let parent = piAgentSessionStore.sessions.first(where: { $0.id == entry.sessionID }) else { return }
        selectedSidebarItem = .agent
        ensurePiAgentModelCatalogLoaded()
        _ = piAgentSessionStore.forkSessionAsAgentChat(
            from: parent,
            agent: agent,
            composerSeed: entry.text,
            cutBeforeEntryID: entry.id
        )
    }

    func refreshPiAgentControlsForSelectedSession() {
        refreshAvailableModels()
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.refreshPiControls(sessionID: sessionID)
    }

    func setPiAgentModelForSelectedSession(provider: String?, modelID: String?) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentRunner.setModel(sessionID: session.id, provider: provider, modelID: modelID)
        if let currentLevel = session.thinkingLevel {
            let fallback = defaultPiAgentModel()
            let levels = supportedPiAgentThinkingLevels(session: session, provider: provider ?? session.modelProvider ?? fallback?.provider, modelID: modelID ?? session.model ?? fallback?.model)
            if !levels.contains(currentLevel == "none" ? "off" : currentLevel) {
                piAgentRunner.setThinkingLevel(sessionID: session.id, level: levels.first ?? "off")
            }
        }
    }

    func cyclePiAgentModelForSelectedSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let options = piAgentModelOptions()
        guard !options.isEmpty else { return }
        let fallback = defaultPiAgentModel()
        let currentProvider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let currentModel = session.modelOverrideID ?? session.model ?? fallback?.model
        let currentIndex = options.firstIndex { $0.provider == currentProvider && $0.id == currentModel } ?? -1
        let next = options[(currentIndex + 1 + options.count) % options.count]
        setPiAgentModelForSelectedSession(provider: next.provider, modelID: next.id)
    }

    func setPiAgentThinkingLevelForSelectedSession(_ level: String) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let normalized = level == "none" ? "off" : level
        let fallback = defaultPiAgentModel()
        let levels = supportedPiAgentThinkingLevels(session: session, provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider, modelID: session.modelOverrideID ?? session.model ?? fallback?.model)
        guard levels.contains(normalized) else {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = LanguageStore.shared.t("vm.thinkingLevelUnavailable", level)
            }
            return
        }
        piAgentRunner.setThinkingLevel(sessionID: session.id, level: normalized)
    }

    func defaultPiAgentModel() -> AvailableModel? {
        _ = piRuntimeSettingsRevision
        let defaults = readPiRuntimeDefaults()
        let provider = defaults.provider
        let model = defaults.model
        if let cached = cachedDefaultPiAgentModelLookup,
           cached.provider == provider,
           cached.model == model,
           cached.modelRevision == modelCacheRevision {
            return cached.result
        }

        let result: AvailableModel?
        if let provider, let model {
            result = cachedEnabledAvailableModelByIdentifier["\(provider)/\(model)"]
                ?? cachedEnabledAvailableModelByModel[model]
                ?? cachedEnabledAvailableModels.first
        } else if let model {
            result = cachedEnabledAvailableModelByIdentifier[model]
                ?? cachedEnabledAvailableModelByModel[model]
                ?? cachedEnabledAvailableModels.first
        } else {
            result = cachedEnabledAvailableModels.first
        }
        cachedDefaultPiAgentModelLookup = (provider, model, modelCacheRevision, result)
        return result
    }

    func defaultPiAgentThinkingLevel(for levels: [String]) -> String {
        _ = piRuntimeSettingsRevision
        let normalized = readPiRuntimeDefaults().thinkingLevel ?? "medium"
        if levels.contains(normalized) { return normalized }
        if levels.contains("medium") { return "medium" }
        return levels.first ?? "off"
    }

    func piRuntimeDefaultThinkingLevel() -> String {
        _ = piRuntimeSettingsRevision
        return readPiRuntimeDefaults().thinkingLevel ?? "medium"
    }

    func readPiRuntimeDefaults() -> (provider: String?, model: String?, thinkingLevel: String?) {
        guard let object = piRuntimeSettingsObject() else {
            cachedPiRuntimeDefaults = (cachedPiRuntimeSettingsModificationDate, nil, nil, nil)
            return (nil, nil, nil)
        }
        let settingsModificationDate = cachedPiRuntimeSettingsModificationDate
        if let cached = cachedPiRuntimeDefaults,
           cached.settingsModificationDate == settingsModificationDate {
            return (cached.provider, cached.model, cached.thinkingLevel)
        }

        let provider = nonEmptyPiSetting(object["defaultProvider"])
        var model = nonEmptyPiSetting(object["defaultModel"])
        var parsedProvider = provider
        if let rawModel = model, rawModel.contains("/") {
            let parts = rawModel.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                parsedProvider = parsedProvider ?? parts[0]
                model = parts[1]
            }
        }
        let rawThinking = nonEmptyPiSetting(object["defaultThinkingLevel"])
        let thinking = (rawThinking ?? "medium") == "none"
            ? "off"
            : rawThinking
        cachedPiRuntimeDefaults = (settingsModificationDate, parsedProvider, model, thinking)
        cachedDefaultPiAgentModelLookup = nil
        return (parsedProvider, model, thinking)
    }

    func writePiRuntimeDefaults(provider: String?, model: String?, thinkingLevel: String?) -> Bool {
        var object = piRuntimeSettingsObject() ?? [:]
        if let provider, let model {
            object["defaultProvider"] = provider
            object["defaultModel"] = model
        }
        if let thinkingLevel {
            let normalized = thinkingLevel == "none" ? "off" : thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
            object["defaultThinkingLevel"] = normalized.isEmpty ? "medium" : normalized
        }
        do {
            let url = piRuntimeSettingsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            cachedPiRuntimeSettingsObject = object
            cachedPiRuntimeSettingsModificationDate = piRuntimeSettingsModificationDate(force: true)
            cachedPiRuntimeDefaults = nil
            cachedDefaultPiAgentModelLookup = nil
            lastPiRuntimeSettingsStatCheck = Date()
            return true
        } catch {
            repositoryLastError = "Could not update Pi settings: \(error.localizedDescription)"
            return false
        }
    }

    func piRuntimeSettingsObject() -> [String: Any]? {
        let modificationDate = piRuntimeSettingsModificationDate()
        guard let modificationDate else {
            cachedPiRuntimeSettingsObject = nil
            cachedPiRuntimeSettingsModificationDate = nil
            cachedPiRuntimeDefaults = nil
            cachedDefaultPiAgentModelLookup = nil
            return nil
        }
        if cachedPiRuntimeSettingsModificationDate == modificationDate {
            return cachedPiRuntimeSettingsObject
        }
        guard let data = try? Data(contentsOf: piRuntimeSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedPiRuntimeSettingsObject = nil
            cachedPiRuntimeSettingsModificationDate = modificationDate
            cachedPiRuntimeDefaults = nil
            cachedDefaultPiAgentModelLookup = nil
            return nil
        }
        cachedPiRuntimeSettingsObject = object
        cachedPiRuntimeSettingsModificationDate = modificationDate
        cachedPiRuntimeDefaults = nil
        cachedDefaultPiAgentModelLookup = nil
        return object
    }

    func piRuntimeSettingsModificationDate(force: Bool = false) -> Date? {
        let now = Date()
        if !force,
           let lastPiRuntimeSettingsStatCheck,
           now.timeIntervalSince(lastPiRuntimeSettingsStatCheck) < 1,
           let cachedPiRuntimeSettingsModificationDate {
            return cachedPiRuntimeSettingsModificationDate
        }
        lastPiRuntimeSettingsStatCheck = now
        return (try? FileManager.default.attributesOfItem(atPath: piRuntimeSettingsURL.path)[.modificationDate]) as? Date
    }

    private var piRuntimeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
    }

    func nonEmptyPiSetting(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func piAgentModelOptions() -> [PiAgentModelOption] {
        return cachedEnabledAvailableModels
            .map { model in
                PiAgentModelOption(
                    provider: model.provider,
                    id: model.model,
                    name: nil,
                    contextWindow: Int(model.contextWindow),
                    maxOutput: model.maxOutput.flatMap { Int($0) },
                    supportsThinking: model.supportsThinking,
                    supportedThinkingLevels: model.supportedThinkingLevels,
                    supportsImages: model.supportsImages
                )
            }
    }

    func supportedPiAgentThinkingLevels(session: PiAgentSessionRecord, provider: String?, modelID: String?) -> [String] {
        if let provider, let modelID {
            if let cached = cachedEnabledAvailableModelByIdentifier["\(provider)/\(modelID)"] {
                if !cached.supportedThinkingLevels.isEmpty { return cached.supportedThinkingLevels }
                return cached.supportsThinking ? [] : ["off"]
            }
        }
        return []
    }

    func cyclePiAgentThinkingLevelForSelectedSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let fallback = defaultPiAgentModel()
        let levels = supportedPiAgentThinkingLevels(session: session, provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider, modelID: session.modelOverrideID ?? session.model ?? fallback?.model)
        guard !levels.isEmpty else { return }
        let current = (session.thinkingLevel ?? defaultPiAgentThinkingLevel(for: levels)) == "none" ? "off" : (session.thinkingLevel ?? defaultPiAgentThinkingLevel(for: levels))
        let currentIndex = levels.firstIndex(of: current) ?? -1
        let next = levels[(currentIndex + 1 + levels.count) % levels.count]
        piAgentRunner.setThinkingLevel(sessionID: session.id, level: next)
    }

    func stopSelectedPiAgentSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.stop(sessionID: sessionID)
        refreshRepositoryChangesForPiAgentSession()
    }

    func respondToPiAgentUIRequest(_ request: PiAgentUIRequest, value: String) {
        piAgentRunner.respondToExtensionUI(sessionID: request.sessionID, requestID: request.id, value: value)
    }

    func respondToPiAgentFreeformUIRequest(_ request: PiAgentUIRequest, sentinel: String, value: String) {
        piAgentRunner.respondToFreeformExtensionUI(sessionID: request.sessionID, requestID: request.id, sentinel: sentinel, value: value)
    }

    func confirmPiAgentUIRequest(_ request: PiAgentUIRequest, confirmed: Bool) {
        piAgentRunner.confirmExtensionUI(sessionID: request.sessionID, requestID: request.id, confirmed: confirmed)
    }

    func cancelPiAgentUIRequest(_ request: PiAgentUIRequest) {
        piAgentRunner.cancelExtensionUI(sessionID: request.sessionID, requestID: request.id)
    }

    func deletePiAgentSession(_ sessionID: UUID) {
        deletePiAgentSessions([sessionID])
    }

    /// Launch-time cleanup: drop drafts that were created but never sent a
    /// message (no Pi session file). Composer text is not persisted across
    /// relaunches, so these records are empty shells — without this they
    /// accumulate one per abandoned "new session". Preserve draft records that
    /// already carry transcript, subagent, or loop activity (loop-launched
    /// sessions may not have a Pi session file). Routed through the normal
    /// delete path so any eagerly provisioned worktrees are reclaimed too.
    func pruneNeverStartedDraftSessions() {
        let staleIDs = Set(
            piAgentSessionStore.sessions
                .filter { session in
                    guard session.status == .draft, session.piSessionFile == nil else { return false }
                    let hasActivity = piAgentSessionStore.hasPersistedTranscript(for: session.id)
                        || !piAgentSessionStore.transcript(for: session.id).isEmpty
                        || !(piAgentSessionStore.subagentRunsBySessionID[session.id] ?? []).isEmpty
                        || !(piAgentSessionStore.loopRunsBySessionID[session.id] ?? []).isEmpty
                    return !hasActivity
                }
                .map(\.id)
        )
        guard !staleIDs.isEmpty else { return }
        deletePiAgentSessions(staleIDs)
    }

    func deletePiAgentSessions(_ sessionIDs: Set<UUID>, fallbackSelectionID: UUID? = nil) {
        if let retainedID = transientFocusedPiAgentSessionID, sessionIDs.contains(retainedID) {
            transientFocusedPiAgentSessionID = nil
        }
        for sessionID in sessionIDs where piAgentRunner.isRunning(sessionID: sessionID)
            || piAgentSessionStore.sessions.first(where: { $0.id == sessionID })?.status == .starting {
            piAgentRunner.stop(sessionID: sessionID, recordTranscript: false)
        }

        let deletedSubagentRuns = sessionIDs.flatMap { piAgentSessionStore.subagentRunsBySessionID[$0] ?? [] }
        let retainedSubagentRuns = piAgentSessionStore.subagentRunsBySessionID
            .filter { !sessionIDs.contains($0.key) }
            .flatMap(\.value)
        let cancelledSubagentRunIDs = nativeSubagentRunner.cancelForSessionDeletion(parentSessionIDs: sessionIDs)
        let deletedSubagentRunIDs = Set(deletedSubagentRuns.map(\.id)).union(cancelledSubagentRunIDs)
        let retainedPiSessionFiles = Set(piAgentSessionStore.sessions
            .filter { !sessionIDs.contains($0.id) }
            .flatMap(\.ownedPiSessionFiles)).union(PiAgentSessionOwnedArtifactCleanup.childPiSessionFiles(in: retainedSubagentRuns))
        let deletedPiSessionFiles = Set(piAgentSessionStore.sessions
            .filter { sessionIDs.contains($0.id) }
            .flatMap(\.ownedPiSessionFiles)).union(PiAgentSessionOwnedArtifactCleanup.childPiSessionFiles(in: deletedSubagentRuns))
            .subtracting(retainedPiSessionFiles)
        for scheduler in nativeParallelSchedulersByID.values where sessionIDs.contains(scheduler.parentSession.id) {
            scheduler.isCancelled = true
        }
        nativeParallelSchedulersByID = nativeParallelSchedulersByID.filter {
            !sessionIDs.contains($0.value.parentSession.id)
        }
        activePipelineChildRunByLoopID = activePipelineChildRunByLoopID.filter {
            !deletedSubagentRunIDs.contains($0.value)
        }

        // Cancel any pending completion-notification timers for sessions being
        // deleted. Without this, a 5-minute-deferred notification task keeps the
        // session ID alive in `pendingPiAgentNotificationTasks` until it fires
        // and harmlessly no-ops because the session is gone.
        for sessionID in sessionIDs {
            pendingPiAgentNotificationTasks[sessionID]?.cancel()
            pendingPiAgentNotificationTasks.removeValue(forKey: sessionID)
        }

        // Best-effort worktree cleanup. We capture the metadata before deleting
        // the session records and then fire-and-forget the git removals.
        let worktreeCleanups: [(worktreePath: String, projectPath: String, branchName: String?, sourceBranch: String?)] = sessionIDs.compactMap { id in
            guard let session = piAgentSessionStore.sessions.first(where: { $0.id == id }),
                  let worktreePath = session.worktreePath else { return nil }
            return (worktreePath, session.projectPath, session.branchName, session.sourceBranch)
        }

        // If the caller handed us the next-visible neighbor (the row below the
        // deleted set in the user's grouped list), hand it to the store so it
        // lands where the user expects instead of clamping to the globally
        // most-recent session. The store ignores the hint when the active
        // selection survives the delete.
        piAgentSessionStore.deleteSessions(sessionIDs, fallbackSelectionID: fallbackSelectionID)
        Task.detached {
            PiAgentSessionOwnedArtifactCleanup.delete(
                piSessionFiles: deletedPiSessionFiles,
                subagentRunIDs: deletedSubagentRunIDs
            )
        }
        // Belt-and-suspenders: still reconcile in the same runloop turn so the
        // UI only ever observes the final selection — without this, launch-time
        // draft pruning briefly selected an out-of-scope session and the
        // correction read as an extra transcript switch. After the fallback
        // above, reconcile is usually a no-op (selection already valid).
        reconcileSelectedSessionWithProjectScope()

        for cleanup in worktreeCleanups {
            let projectURL = URL(fileURLWithPath: cleanup.projectPath, isDirectory: true)
            Task { [weak self] in
                try? await self?.sessionWorktreeService.removeWorktree(
                    worktreePath: cleanup.worktreePath,
                    projectURL: projectURL,
                    branchName: cleanup.branchName,
                    sourceBranch: cleanup.sourceBranch,
                    deleteBranch: true,
                    force: true
                )
            }
        }
    }

}
