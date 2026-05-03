import Foundation

struct SubagentConfigPersistence {
    func makeDraft(path: String, config: SubagentExtensionConfig) -> SubagentConfigDraft {
        SubagentConfigDraft(path: path, config: config)
    }

    func save(_ draft: SubagentConfigDraft) throws {
        let fileURL = URL(fileURLWithPath: draft.path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let value = draft.config.asyncByDefault { root["asyncByDefault"] = value }
        if let value = draft.config.forceTopLevelAsync { root["forceTopLevelAsync"] = value }
        if let value = normalizedOptionalString(draft.config.defaultSessionDir) { root["defaultSessionDir"] = value }
        if let value = draft.config.maxSubagentDepth { root["maxSubagentDepth"] = value }

        var control: [String: Any] = [:]
        if let value = draft.config.control.enabled { control["enabled"] = value }
        if let value = draft.config.control.needsAttentionAfterMs { control["needsAttentionAfterMs"] = value }
        let notifyChannels = draft.config.control.notifyChannels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !notifyChannels.isEmpty { control["notifyChannels"] = notifyChannels }
        if !control.isEmpty { root["control"] = control }

        var parallel: [String: Any] = [:]
        if let value = draft.config.parallel.maxTasks { parallel["maxTasks"] = value }
        if let value = draft.config.parallel.concurrency { parallel["concurrency"] = value }
        if !parallel.isEmpty { root["parallel"] = parallel }

        if let value = normalizedOptionalString(draft.config.worktreeSetupHook) { root["worktreeSetupHook"] = value }
        if let value = draft.config.worktreeSetupHookTimeoutMs { root["worktreeSetupHookTimeoutMs"] = value }

        var intercomBridge: [String: Any] = [:]
        if let value = normalizedOptionalString(draft.config.intercomBridge.mode) { intercomBridge["mode"] = value }
        if let value = normalizedOptionalString(draft.config.intercomBridge.instructionFile) { intercomBridge["instructionFile"] = value }
        if !intercomBridge.isEmpty { root["intercomBridge"] = intercomBridge }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct EnvPersistence {
    private let fileManager = FileManager.default

    func makeDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        EnvEditorDraft(
            originalKey: record.key,
            key: record.key,
            value: record.value ?? "",
            path: record.source.path,
            scope: record.source.kind
        )
    }

    func makeNewDraft(scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> EnvEditorDraft {
        let path = switch scope {
        case .library, .global:
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/.env").path
        case .project:
            URL(fileURLWithPath: projectRoot ?? "").appendingPathComponent(".pi/.env").path
        }

        return EnvEditorDraft(
            originalKey: nil,
            key: "NEW_KEY",
            value: "",
            path: path,
            scope: scope == .project ? .project : .global
        )
    }

    func save(_ draft: EnvEditorDraft) throws {
        guard isWritableEnvPath(draft.path) else {
            throw PersistenceError.invalidWriteTarget(draft.path)
        }

        let url = URL(fileURLWithPath: draft.path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let originalKey = draft.originalKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLine = "\(key)=\(draft.value)"

        var output: [String] = []
        var wroteNewLine = false
        var sawOriginalKey = false

        for line in existingText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let lineKey = envKey(from: trimmed)

            if let originalKey, lineKey == originalKey {
                sawOriginalKey = true
                if !wroteNewLine {
                    output.append(newLine)
                    wroteNewLine = true
                }
                continue
            }

            if originalKey != key, lineKey == key {
                if !wroteNewLine {
                    output.append(newLine)
                    wroteNewLine = true
                }
                continue
            }

            output.append(raw)
        }

        if !wroteNewLine {
            if !output.isEmpty, output.last?.isEmpty == false {
                output.append("")
            }
            output.append(newLine)
        } else if !sawOriginalKey && !existingText.isEmpty && !output.contains(newLine) {
            output.append(newLine)
        }

        var text = output.joined(separator: "\n")
        if !text.hasSuffix("\n") { text.append("\n") }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func envKey(from line: String) -> String? {
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        return line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    private func isWritableEnvPath(_ path: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if path == URL(fileURLWithPath: home).appendingPathComponent(".pi/agent/.env").path { return true }
        return path.contains("/.pi/.env")
    }
}
