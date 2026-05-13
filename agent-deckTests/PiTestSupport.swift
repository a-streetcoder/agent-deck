import Foundation
import XCTest
@testable import agent_deck

enum PiTestSupport {
    struct RPCHarness {
        let stdinLog: URL
        let restoreEnvironment: () -> Void
    }

    struct EnvCaptureHarness {
        let envLog: URL
        let restoreEnvironment: () -> Void
    }

    static func temporaryStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    static func temporaryProjectURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-test-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    static func makeProject(url: URL? = nil) throws -> DiscoveredProject {
        let projectURL = try url ?? temporaryProjectURL()
        return DiscoveredProject(
            url: projectURL,
            gitHubRemote: nil,
            isGitRepository: true,
            iconFileURL: nil,
            fallbackSymbolName: "folder",
            searchIndex: "agent-deck-test-project"
        )
    }

    @MainActor
    static func makeParentSession(
        projectURL: URL? = nil,
        model: String? = nil,
        provider: String? = nil,
        thinking: String? = nil,
        piSessionFile: String? = nil,
        subagentsEnabled: Bool = true
    ) throws -> PiAgentSessionRecord {
        let projectURL = try projectURL ?? temporaryProjectURL()
        return PiAgentSessionRecord(
            id: UUID(),
            kind: .project,
            title: "Parent",
            projectPath: projectURL.path,
            projectName: projectURL.lastPathComponent,
            repository: nil,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: piSessionFile,
            piSessionId: nil,
            model: model,
            modelProvider: provider,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            availableModels: nil,
            thinkingLevel: thinking,
            launchCommand: nil,
            branchName: nil,
            worktreePath: nil,
            status: .draft,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
            lastNotificationAt: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: nil,
            toolCalls: nil,
            toolResults: nil,
            contextTokens: nil,
            contextWindow: nil,
            contextPercent: nil,
            cost: nil,
            finalSystemPrompt: nil,
            finalSystemPromptCapturedAt: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: subagentsEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @MainActor
    static func makeAgent(
        name: String = "scout",
        model: String? = nil,
        thinking: String? = nil,
        tools: [String]? = nil,
        extensions: [String]? = nil,
        skills: [String] = [],
        output: String? = nil,
        defaultReads: [String]? = nil,
        inheritSkills: Bool? = nil,
        systemPromptMode: String? = nil,
        systemPrompt: String = ""
    ) -> EffectiveAgentRecord {
        var config = AgentConfig.empty
        config.name = name
        config.description = name
        config.model = model
        config.thinking = thinking
        config.systemPromptMode = systemPromptMode
        config.systemPrompt = systemPrompt
        config.inheritSkills = inheritSkills
        config.tools = tools
        config.extensions = extensions
        config.skills = skills
        config.output = output
        config.defaultReads = defaultReads
        return EffectiveAgentRecord(
            id: name,
            name: name,
            projectRoot: "/tmp/agent-deck-test-project",
            builtin: nil,
            globalCustom: nil,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: config,
            resolutionKind: .builtin
        )
    }

    static func makeBridgeHarness(event: [String: Any]) throws -> RPCHarness {
        try makeBridgeHarness(events: [event])
    }

    static func makeBridgeHarness(events: [[String: Any]]) throws -> RPCHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdinLog = directory.appendingPathComponent("stdin.log")
        let executable = directory.appendingPathComponent("pi")
        let eventFiles = try events.enumerated().map { index, event -> URL in
            let eventFile = directory.appendingPathComponent("event-\(index).json")
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            try data.write(to: eventFile)
            return eventFile
        }

        let script = """
        #!/bin/sh
        sleep 0.2
        \(eventFiles.map { "cat \(shellSingleQuoted($0.path)); printf '\\n'" }.joined(separator: "\n"))
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> \(shellSingleQuoted(stdinLog.path))
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        return RPCHarness(stdinLog: stdinLog) {
            if let oldPiPath {
                setenv("AGENT_DECK_PI_PATH", oldPiPath, 1)
            } else {
                unsetenv("AGENT_DECK_PI_PATH")
            }
        }
    }

    static func makeFakePiExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-fake-pi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("pi")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          sleep 1
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    static func makeEnvCaptureHarness(keys: [String]) throws -> EnvCaptureHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-deck-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envLog = directory.appendingPathComponent("env.log")
        let executable = directory.appendingPathComponent("pi")
        let lines = keys.map { key in
            "printf '\(key)=%s\\n' \"${\(key)-}\""
        }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        {
        \(lines)
        } > \(shellSingleQuoted(envLog.path))
        while IFS= read -r line; do
          sleep 1
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let oldPiPath = getenv("AGENT_DECK_PI_PATH").map { String(cString: $0) }
        setenv("AGENT_DECK_PI_PATH", executable.path, 1)
        return EnvCaptureHarness(envLog: envLog) {
            if let oldPiPath {
                setenv("AGENT_DECK_PI_PATH", oldPiPath, 1)
            } else {
                unsetenv("AGENT_DECK_PI_PATH")
            }
        }
    }

    static func capturedEnvironment(in logURL: URL) -> [String: String] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            values[String(key)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return values
    }

    static func extensionUIResponses(in logURL: URL) -> [[String: Any]] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "extension_ui_response" else {
                    return nil
                }
                return object
            }
    }

    static func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
