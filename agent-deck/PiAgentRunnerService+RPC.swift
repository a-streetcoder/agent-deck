import Foundation
import os

// MARK: - Inbound RPC routing and response handling

@MainActor
extension PiAgentRunnerService {
    func handle(rawLine: String, event: PiAgentRPCEvent?, sessionID: UUID, clientRunID: UUID) {
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
            } else if event.type == "agent_end" {
                // No final message payload (thinking-only turn, or provider omitted body).
                // Persist any streamed thinking/text, then drop the empty turn_start
                // placeholder so confirmIdle is not blocked by assistantText == "".
                finalizeOrphanStreamingBuffers(sessionID: sessionID)
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

    func handleResponse(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
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
            // Do not wipe context usage here: clearing meters made the composer
            // context size disappear after compact until a later stats payload
            // re-populated it (and some get_session_stats replies omit contextUsage).
            store.updateSession(sessionID) {
                $0.isCompacting = false
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
                }
                // When contextUsage is omitted, retain previous meters. Clearing here
                // left the UI blank after compact if Pi stats lag or omit the field.
            }
        }
    }

    static func parseContextBreakdown(from contextUsage: JSONValue) -> [PiAgentContextBreakdownItem] {
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

    static func parseContextBreakdownCandidate(_ value: JSONValue, contextWindow: Double?) -> [PiAgentContextBreakdownItem] {
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

    static func parseContextBreakdownItem(_ value: JSONValue?, fallbackKey: String?, contextWindow: Double?) -> PiAgentContextBreakdownItem? {
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

    static func firstNumber(in object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key]?.numberValue {
                return value
            }
        }
        return nil
    }

    static func contextBreakdownKeys(_ keys: [String]) -> [String] {
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

    static func contextBreakdownTitle(for key: String) -> String {
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

    func normalizedThinkingLevel(_ level: String?) -> String? {
        guard let level = level?.trimmingCharacters(in: .whitespacesAndNewlines), !level.isEmpty else { return nil }
        return level == "none" ? "off" : level
    }

    func applyState(_ data: JSONValue, to sessionID: UUID) {
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

    func updateModelFields(on record: inout PiAgentSessionRecord, from modelObject: JSONValue, useAsOverride: Bool) {
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
    func parseRuntimeSlashCommands(from value: JSONValue) -> [PiRuntimeSlashCommand] {
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

    func parseCommandInvocations(from value: JSONValue) -> [String] {
        Array(Set(parseRuntimeSlashCommands(from: value).map(\.invocation))).sorted()
    }

    func stringArray(from value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.isEmpty ? nil : strings
    }

    func handleMessageUpdate(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
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
}
