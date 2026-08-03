import Foundation
import os

// MARK: - Extension UI, Deck bridges, UI request parse

@MainActor
extension PiAgentRunnerService {
    func handleExtensionUIRequest(_ event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) {
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

        // notify → soft transcript cards (unchanged).
        // setStatus / setWidget → per-session footer chrome (keyed overwrite, not history).
        switch method {
        case "notify":
            appendExtensionSystemNotice(event, rawLine: rawLine, sessionID: sessionID, kind: .notify)
        case "setStatus":
            applyExtensionSetStatus(event, rawLine: rawLine, sessionID: sessionID)
        case "setWidget":
            applyExtensionSetWidget(event, sessionID: sessionID)
        case "setTitle", "set_editor_text":
            // Title/editor chrome is not modeled in the transcript.
            break
        default:
            break
        }
    }

    /// Apply extension `setStatus` into the session chrome strip (no transcript row).
    ///
    /// - Parameters:
    ///   - event: Decoded extension_ui_request. Required.
    ///   - rawLine: Raw JSONL for message fallback. Required.
    ///   - sessionID: Owning Deck session. Required.
    func applyExtensionSetStatus(
        _ event: PiAgentRPCEvent,
        rawLine: String,
        sessionID: UUID
    ) {
        let key = event.statusKey
            ?? extensionUIString("statusKey", from: event)
            ?? extensionUIString("key", from: event)
            ?? extensionNotifyTopLevelString("statusKey", from: rawLine)
            ?? extensionNotifyTopLevelString("key", from: rawLine)
            ?? "status"
        // Prefer stripAnsi only — sanitizeAnswer may drop short status labels.
        let text = event.statusText
            ?? extensionUIString("statusText", from: event)
            ?? extensionUIString("text", from: event)
            ?? extensionNotifyTopLevelString("statusText", from: rawLine)
            ?? extensionNotifyTopLevelString("text", from: rawLine)
            ?? ""
        // `undefined` clear from Pi arrives as null/omitted → empty → remove key.
        let sanitized = TextSanitizer.stripAnsi(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        store.applyExtensionSetStatus(sessionID: sessionID, key: key, text: sanitized)
    }

    /// Apply extension `setWidget` into the session chrome strip (no transcript row).
    ///
    /// - Parameters:
    ///   - event: Decoded extension_ui_request. Required.
    ///   - sessionID: Owning Deck session. Required.
    func applyExtensionSetWidget(
        _ event: PiAgentRPCEvent,
        sessionID: UUID
    ) {
        let key = event.widgetKey
            ?? extensionUIString("widgetKey", from: event)
            ?? extensionUIString("key", from: event)
            ?? "widget"
        let lines = extensionUIStringList(event.widgetLines)
            ?? extensionUIStringList(event.data?["widgetLines"])
            ?? extensionUIStringList(event.data?["lines"])
            ?? extensionUIStringList(event.message?["widgetLines"])
            ?? []
        let cleaned = lines.map { TextSanitizer.stripAnsi($0) }
        store.applyExtensionSetWidget(sessionID: sessionID, key: key, lines: cleaned)
    }

    /// Append a soft system-notice card for extension `notify` only.
    ///
    /// `setStatus` / `setWidget` use the footer chrome strip instead.
    ///
    /// - Parameters:
    ///   - event: Decoded extension_ui_request. Required.
    ///   - rawLine: Raw JSONL fallback for message parse. Required.
    ///   - sessionID: Owning Deck session. Required.
    ///   - kind: Must be `.notify` (parameter kept for call-site clarity).
    func appendExtensionSystemNotice(
        _ event: PiAgentRPCEvent,
        rawLine: String,
        sessionID: UUID,
        kind: ExtensionSystemNoticeKind
    ) {
        guard kind == .notify else { return }
        let rawMessage = extensionNotifyMessage(from: event, rawLine: rawLine)
        let body = TextSanitizer.sanitizeAnswer(rawMessage ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let levelRaw = event.notifyType
            ?? extensionUIString("notifyType", from: event)
            ?? extensionNotifyTopLevelString("notifyType", from: rawLine)
        let title: String
        switch (levelRaw ?? "").lowercased() {
        case "warning", "warn": title = "Notify Warning"
        case "error", "danger", "fail", "failure": title = "Notify Error"
        default: title = "Notify"
        }
        // Collapse consecutive identical soft cards (double RPC / resume).
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

    enum ExtensionSystemNoticeKind {
        case notify
    }

    /// Resolve notify message from decoded event, nested keys, then raw JSON.
    ///
    /// - Parameters:
    ///   - event: Decoded RPC event. Required.
    ///   - rawLine: Raw JSONL line. Required.
    /// - Returns: Message when present.
    func extensionNotifyMessage(from event: PiAgentRPCEvent, rawLine: String) -> String? {
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
    func extensionNotifyTopLevelString(_ key: String, from rawLine: String) -> String? {
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

    func handleMemoryMarkStaleBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleMemorySearchBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleMemoryWriteBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleMCPBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleManagedSubagentBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleManagedParallelBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleAnswerSupervisorBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSupervisorAnswerBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the supervisor response request.")
            return
        }
        let result = onSupervisorRequestAnswer?(sessionID, request.requestID, request.response) ?? "\(AppBrand.displayName) supervisor routing is not available."
        store.append(.init(sessionID: sessionID, role: .status, title: LanguageStore.shared.t("run.supervisorResponseRouted"), text: request.requestID, rawJSON: rawLine))
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    func handleSetSessionPlanBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSessionPlanSetBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the session plan request.")
            return
        }
        let result = onSessionPlanSet?(sessionID, request) ?? "\(AppBrand.displayName) session plan routing is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    func handleUpdateSessionPlanBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
        guard let payload = bridgePayload(from: event),
              let request = try? JSONDecoder().decode(PiSessionPlanUpdateBridgeRequest.self, from: Data(payload.utf8)) else {
            clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: "\(AppBrand.displayName) could not parse the session plan update.")
            return
        }
        let result = onSessionPlanUpdate?(sessionID, request) ?? "\(AppBrand.displayName) session plan routing is not available."
        clientsBySessionID[sessionID]?.respondToExtensionUI(id: requestID, value: result)
    }

    func handleSystemPromptAuditBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func handleNativeAskUserBridgeRequest(_ event: PiAgentRPCEvent, requestID: String, rawLine: String, sessionID: UUID) {
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

    func bridgePayload(from event: PiAgentRPCEvent) -> String? {
        if let prefill = nonEmptyBridgeString(event.prefill) { return prefill }
        if let prefill = extensionUIString("prefill", from: event) { return prefill }
        if let message = event.message?.stringValue, !message.isEmpty { return message }
        if let message = extensionUIString("message", from: event) { return message }
        return event.message?.compactDescription
    }

    func agentDeckBridgeName(from event: PiAgentRPCEvent) -> String? {
        guard let title = extensionUITitle(from: event) else { return nil }
        let prefix = "AGENT_DECK_BRIDGE "
        guard title.hasPrefix(prefix) else { return nil }
        let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func extensionUITitle(from event: PiAgentRPCEvent) -> String? {
        if let title = nonEmptyBridgeString(event.title) { return title }
        if let title = extensionUIString("title", from: event) { return title }
        if let method = nonEmptyBridgeString(event.method), method.hasPrefix("AGENT_DECK_BRIDGE ") { return method }
        return nil
    }

    func extensionUIRequestID(from event: PiAgentRPCEvent) -> String? {
        nonEmptyBridgeString(event.id) ?? extensionUIString("id", from: event)
    }

    func extensionUIString(_ key: String, from event: PiAgentRPCEvent) -> String? {
        nonEmptyBridgeString(event.data?[key]?.stringValue)
            ?? nonEmptyBridgeString(event.message?[key]?.stringValue)
            ?? nonEmptyBridgeString(event.result?[key]?.stringValue)
    }

    /// Flatten a JSON string or string-array into display lines for setWidget.
    ///
    /// - Parameter value: Optional JSON value from RPC. Optional.
    /// - Returns: Non-empty string list when parseable.
    func extensionUIStringList(_ value: JSONValue?) -> [String]? {
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

    func nonEmptyBridgeString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func parsedUIRequest(
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

    func parseMultiSelectInputTitle(_ title: String) -> (question: String, context: String?, options: [String])? {
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
}
