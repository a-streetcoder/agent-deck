import Foundation
import os

// MARK: - Session file, user/transcript helpers, stderr

@MainActor
extension PiAgentRunnerService {
    func appendSessionInfo(name: String, to sessionFile: String) {
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

    func makeShortSessionEntryID(excluding existingIDs: Set<String>) -> String {
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
        EphemeralSlashCommand.shouldOmitFromTranscript(
            text: text,
            hasAttachments: !images.isEmpty || !pasteAttachments.isEmpty
        )
    }

    /// Builds the canonical Pi RPC prompt. Attachment-only transcript labels are
    /// projected by the renderer and must never change this source text.
    func userMessage(_ text: String, images: [PiAgentImageAttachment]) -> String {
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

    func imageFileTag(for image: PiAgentImageAttachment) -> String {
        "<file name=\"\(image.fileReference ?? image.name)\">\(image.dimensionNote ?? "")</file>"
    }

    func transcriptTitle(for mode: PiAgentInputMode, isStreaming: Bool) -> String {
        guard isStreaming else { return LanguageStore.shared.t("run.prompt") }
        switch mode {
        case .prompt, .steer: return LanguageStore.shared.t("run.steering")
        case .followUp: return LanguageStore.shared.t("run.queuedFollowUp")
        }
    }

    func transcriptText(_ text: String, images: [PiAgentImageAttachment]) -> String {
        visibleUserText(text, imageReferences: Set(images.compactMap { $0.fileReference ?? $0.name }))
    }

    func transcriptAttachmentJSON(messageText: String?, images: [PiAgentImageAttachment], pasteAttachments: [PiAgentPasteAttachment] = []) -> String? {
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
    func extractedFileAttachments(in text: String, imageReferences: Set<String>) -> [(name: String, path: String)] {
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

    func visibleUserText(_ text: String, imageReferences: Set<String> = []) -> String {
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

    func handle(stderr: String, sessionID: UUID, clientRunID: UUID) {
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

    func isIgnorableStderr(_ text: String) -> Bool {
        text.contains(";notify;Pi;") || text.localizedCaseInsensitiveContains("ready for input")
    }

    func isCurrentClientRun(_ clientRunID: UUID, for sessionID: UUID) -> Bool {
        clientRunIDsBySessionID[sessionID] == clientRunID
    }

    func isConnectionError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("websocket")
            || lower.contains("socket hang up")
            || lower.contains("econnreset")
            || lower.contains("connection reset")
            || lower.contains("connection closed")
            || lower.contains("network error")
    }

    func normalizedConnectionError(_ text: String) -> String {
        text
            .replacingOccurrences(of: "WebSocket error:", with: "WebSocket error ·")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
