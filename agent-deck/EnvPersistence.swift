import Foundation

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

    func makeNewDraft(scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?, prefilledKey: String? = nil) -> EnvEditorDraft {
        let scopeKind: ResourceScopeKind = scope == .project ? .project : .global
        return EnvEditorDraft(
            originalKey: nil,
            key: prefilledKey ?? "",
            value: "",
            path: Self.envFilePath(scope: scopeKind, projectRoot: projectRoot),
            scope: scopeKind
        )
    }

    /// Absolute path of the `.env` file backing a given scope. `project` resolves
    /// to `<projectRoot>/.pi/.env`; every other scope resolves to the shared
    /// `~/.pi/agent/.env`. Exposed statically so the editor sheet can retarget a
    /// new key live when the user flips the scope picker.
    static func envFilePath(scope: ResourceScopeKind, projectRoot: String?) -> String {
        switch scope {
        case .project:
            return URL(fileURLWithPath: projectRoot ?? "")
                .appendingPathComponent(".pi/.env").path
        default:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/.env").path
        }
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

    func delete(_ record: EnvKeyRecord) throws {
        guard isWritableEnvPath(record.source.path) else {
            throw PersistenceError.invalidWriteTarget(record.source.path)
        }

        let url = URL(fileURLWithPath: record.source.path)
        let existingText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let key = record.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = existingText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                envKey(from: line.trimmingCharacters(in: .whitespaces)) != key
            }

        var text = output.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text.append("\n") }
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

struct EnvRuntimeEnvironment {
    struct ParsedFile {
        let path: String
        let values: [String: String]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func environment(projectRoot: URL?, base: [String: String] = ProcessInfo.processInfo.environment, extra: [String: String] = [:]) -> [String: String] {
        let globalEnv = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/.env")
        let projectEnv = projectRoot?.appendingPathComponent(".pi/.env")
        return environment(globalEnv: globalEnv, projectEnv: projectEnv, base: base, extra: extra)
    }

    func environment(globalEnv: URL?, projectEnv: URL?, base: [String: String] = ProcessInfo.processInfo.environment, extra: [String: String] = [:]) -> [String: String] {
        var merged = base
        for file in parsedFiles(globalEnv: globalEnv, projectEnv: projectEnv) {
            merged.merge(file.values) { _, new in new }
        }
        merged.merge(extra) { _, new in new }
        return merged
    }

    func parsedFiles(globalEnv: URL?, projectEnv: URL?) -> [ParsedFile] {
        [globalEnv, projectEnv].compactMap { url in
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let values = parse(text)
            return values.isEmpty ? nil : ParsedFile(path: url.path, values: values)
        }
    }

    private func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = parts.first else { continue }
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
            var value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"" || first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            values[String(key)] = value
        }
        return values
    }
}
