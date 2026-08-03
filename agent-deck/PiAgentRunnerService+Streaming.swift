import Foundation
import os

// MARK: - Streaming flush, tools, compaction, rehydrate

@MainActor
extension PiAgentRunnerService {
    func scheduleStreamingFlush(sessionID: UUID) {
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

    func streamingFlushDelay(for sessionID: UUID) -> UInt64 {
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

    func flushStreamingEntries(sessionID: UUID) {
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

    func clearStreamingState(sessionID: UUID) {
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

    func handleMessageEnd(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        guard let message = event.message else { return }
        finalizeCompletedMessage(message, rawLine: rawLine, sessionID: sessionID)
    }

    func finalizeCompletedMessage(_ message: JSONValue, rawLine: String, sessionID: UUID) {
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

    func rememberPiMessage(_ message: JSONValue, sessionID: UUID) {
        let key = message["id"]?.stringValue ?? message.compactDescription
        var messages = piMessagesBySessionID[sessionID] ?? []
        guard !messages.contains(where: { ($0["id"]?.stringValue ?? $0.compactDescription) == key }) else { return }
        messages.append(message)
        piMessagesBySessionID[sessionID] = messages
    }

    func applyVerifiedCostBreakdownIfPossible(sessionID: UUID, messages: [JSONValue]) {
        store.updateSession(sessionID) { record in
            record.costBreakdown = PiAgentUsageCostBreakdown.verifiedAssistantCategoryCosts(
                from: messages,
                statsTotalCost: record.cost
            )
        }
    }

    func applyAssistantUsage(_ usage: JSONValue?, sessionID: UUID) {
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

    func recentAssistantEntryExists(with text: String, sessionID: UUID, excluding excludedID: UUID? = nil) -> Bool {
        store.transcript(for: sessionID)
            .reversed()
            .prefix(8)
            .contains { $0.role == .assistant && $0.id != excludedID && $0.text == text }
    }

    func recentErrorEntryExists(with text: String, sessionID: UUID) -> Bool {
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
    func applyRehydratedMessages(_ piMessages: [JSONValue], sessionID: UUID) {
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
    func transcriptEntries(
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
    static func rehydratedToolRawJSON(toolName: String, args: JSONValue) -> String? {
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

    func finalAssistantMessage(from event: PiAgentRPCEvent) -> JSONValue? {
        if let message = event.message,
           (message["role"]?.stringValue ?? "assistant") == "assistant" {
            return message
        }
        guard case let .array(messages) = event.messages else { return nil }
        return messages.last { ($0["role"]?.stringValue ?? "") == "assistant" }
    }

    func handleToolExecution(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
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

    static func mcpSafeResultText(_ result: JSONValue?) -> String? {
        guard case let .array(blocks)? = result?["content"] else { return nil }
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
        if !text.isEmpty { return text }
        return blocks.contains { $0["type"]?.stringValue == "image" } ? "MCP returned an image." : nil
    }

    /// Returns `rawLine` (a JSON object string) with the tool-call `args` re-attached
    /// under the top-level `args` key. Used so update/end tool events keep the call's
    /// arguments that only the start event carried. Returns nil if `rawLine` isn't a
    /// JSON object or the args can't be encoded (caller falls back to `rawLine`).
    static func rawJSON(_ rawLine: String, attaching args: JSONValue) -> String? {
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
    /// When `agent_end` arrives without a final assistant message, still close
    /// any open thinking/text stream and clear the empty turn_start placeholder.
    /// Without this, `assistantTextBySessionID == ""` permanently fails
    /// `confirmIdleIfStillEligible` and the session stays "running" forever.
    func finalizeOrphanStreamingBuffers(sessionID: UUID) {
        streamFlushTasksBySessionID[sessionID]?.cancel()
        streamFlushTasksBySessionID[sessionID] = nil

        if let thinkingEntryID = thinkingEntryIDsBySessionID[sessionID],
           let thinkingText = thinkingTextBySessionID[sessionID],
           !thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let display = TextSanitizer.sanitizeThinking(thinkingText)
            if !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.upsert(
                    .init(
                        id: thinkingEntryID,
                        sessionID: sessionID,
                        role: .thinking,
                        title: LanguageStore.shared.t("run.thinking"),
                        text: display,
                        rawJSON: nil
                    ),
                    before: assistantEntryIDsBySessionID[sessionID],
                    revisionPolicy: .immediateForSelectedSession
                )
            }
        }

        if let assistantEntryID = assistantEntryIDsBySessionID[sessionID],
           let assistantText = assistantTextBySessionID[sessionID],
           !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.upsert(
                .init(
                    id: assistantEntryID,
                    sessionID: sessionID,
                    role: .assistant,
                    title: LanguageStore.shared.t("run.assistant"),
                    text: TextSanitizer.sanitizeAnswer(assistantText),
                    rawJSON: nil
                ),
                revisionPolicy: .immediateForSelectedSession
            )
        }

        thinkingEntryIDsBySessionID[sessionID] = nil
        thinkingTextBySessionID[sessionID] = nil
        assistantEntryIDsBySessionID[sessionID] = nil
        assistantTextBySessionID[sessionID] = nil
        store.setProcessingActivity(nil, for: sessionID)
    }

    func finalizeStreamingThinking(sessionID: UUID) {
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
    func toolActivityDetail(toolName: String, args: JSONValue?) -> String? {
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
    func condensedSingleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let condensed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return condensed.isEmpty ? nil : condensed
    }

    func handleCompaction(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let reason = event.reason ?? event.data?["reason"]?.stringValue ?? event.result?["reason"]?.stringValue ?? "context"
        let entryID = compactionEntryIDsBySessionID[sessionID] ?? UUID()
        compactionEntryIDsBySessionID[sessionID] = entryID

        let text: String
        if event.type == "compaction_start" {
            store.updateSession(sessionID) { $0.isCompacting = true }
            text = "Compacting conversation context (\(reason))…"
        } else if event.result != nil {
            // Keep last known context meters until get_session_stats refreshes them.
            store.updateSession(sessionID) {
                $0.isCompacting = false
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

    func handleRetry(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
        let text = event.errorMessage ?? event.data?.compactDescription ?? rawLine
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.retry"), text: text, rawJSON: rawLine))
    }

    func handleQueueUpdate(_ event: PiAgentRPCEvent, sessionID: UUID) {
        store.updateSession(sessionID) { record in
            record.pendingSteeringMessages = stringArray(from: event.steering) ?? []
            record.pendingFollowUpMessages = stringArray(from: event.followUp) ?? []
        }
    }
}
