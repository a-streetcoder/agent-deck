import Foundation

/// Internal, app-owned hooks that Agent Deck runs around Pi launches and built-in
/// loop validation. These are deliberately not user-configurable and are not a
/// public hook API.
nonisolated enum AgentDeckBuiltinHooks {
    struct ParentPiLaunchContext {
        var session: PiAgentSessionRecord
        var projectURL: URL
        var extraArguments: [String]
        var environment: [String: String]
    }

    struct ParentPiFinishContext {
        var sessionID: UUID
        var status: PiAgentRunStatus
        var exitCode: Int32?
    }

    struct NativeSubagentLaunchContext {
        var parentSessionID: UUID
        var runID: UUID
        var agentName: String
        var projectURL: URL
        var artifactDirectory: URL
        var extraArguments: [String]
        var environment: [String: String]
        var isContinuation: Bool
    }

    struct NativeSubagentFinishContext {
        var parentSessionID: UUID
        var runID: UUID
        var status: PiSubagentRunStatus
        var exitCode: Int32?
    }

    struct ValidationContext {
        var command: String
        var workingDirectory: URL?
        var outputDirectory: URL
        var timeout: TimeInterval = 30
    }

    static func preLaunch(_ context: ParentPiLaunchContext) throws {
        // Reserved for Agent Deck-owned built-ins. Intentionally no-op today.
    }

    static func afterFinish(_ context: ParentPiFinishContext) {
        // Reserved for Agent Deck-owned built-ins. Intentionally no-op today.
    }

    static func preLaunch(_ context: NativeSubagentLaunchContext) throws {
        // Reserved for Agent Deck-owned built-ins. Intentionally no-op today.
    }

    static func afterFinish(_ context: NativeSubagentFinishContext) {
        // Reserved for Agent Deck-owned built-ins. Intentionally no-op today.
    }

    static func runValidation(_ context: ValidationContext) -> LoopValidationResult {
        let startedAt = Date()
        let stdoutURL = context.outputDirectory.appendingPathComponent("\(UUID().uuidString)-stdout.txt")
        let stderrURL = context.outputDirectory.appendingPathComponent("\(UUID().uuidString)-stderr.txt")
        do {
            try FileManager.default.createDirectory(at: context.outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            let terminationSemaphore = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", context.command]
            process.currentDirectoryURL = context.workingDirectory
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            process.terminationHandler = { _ in terminationSemaphore.signal() }
            try process.run()
            let timedOut = terminationSemaphore.wait(timeout: .now() + context.timeout) == .timedOut
            if timedOut {
                process.terminate()
                process.waitUntilExit()
            }

            var stderr = cappedText(at: stderrURL)
            if timedOut {
                let seconds = Int(context.timeout)
                stderr += stderr.isEmpty ? "Validation command timed out after \(seconds) seconds." : "\nValidation command timed out after \(seconds) seconds."
            }
            return LoopValidationResult(
                command: context.command,
                workingDirectory: context.workingDirectory?.path,
                exitCode: timedOut ? nil : Int(process.terminationStatus),
                duration: Date().timeIntervalSince(startedAt),
                stdout: cappedText(at: stdoutURL),
                stderr: stderr,
                stdoutPath: stdoutURL.path,
                stderrPath: stderrURL.path
            )
        } catch {
            return LoopValidationResult(
                command: context.command,
                workingDirectory: context.workingDirectory?.path,
                exitCode: nil,
                duration: Date().timeIntervalSince(startedAt),
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }

    private static func cappedText(at url: URL, byteLimit: Int = 16 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit + 1)) ?? Data()
        let capped = data.count > byteLimit ? data.prefix(byteLimit) : data[...]
        var text = String(decoding: capped, as: UTF8.self)
        if data.count > byteLimit {
            text += "\n… output truncated …"
        }
        return text
    }
}
