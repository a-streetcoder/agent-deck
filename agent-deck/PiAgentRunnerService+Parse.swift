import Foundation
import os

// MARK: - Message extract, termination, status mark

@MainActor
extension PiAgentRunnerService {
    func transcriptEntry(from event: PiAgentRPCEvent, rawLine: String, sessionID: UUID) -> PiAgentTranscriptEntry? {
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

    func extractText(from message: JSONValue) -> String {
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

    func extractAssistantText(from message: JSONValue) -> String {
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
    func assistantErrorMessage(from message: JSONValue) -> String? {
        if let raw = message["errorMessage"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if message["stopReason"]?.stringValue == "error" {
            return "The model provider returned an error."
        }
        return nil
    }

    func extractAssistantThinking(from message: JSONValue) -> String {
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

    func handleTermination(exitCode: Int32, sessionID: UUID, clientRunID: UUID) {
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

    func runAfterFinishHookIfNeeded(sessionID: UUID, clientRunID: UUID, status: PiAgentRunStatus, exitCode: Int32?) {
        guard afterFinishHookRunIDs.insert(clientRunID).inserted else { return }
        AgentDeckBuiltinHooks.afterFinish(.init(sessionID: sessionID, status: status, exitCode: exitCode))
    }

    func mark(_ sessionID: UUID, status: PiAgentRunStatus, error: String?) {
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
