import Foundation

struct CommandResult: Hashable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum CommandRunnerError: LocalizedError {
    case launchFailed(command: String, underlying: Error)
    case timedOut(command: String, timeout: TimeInterval)
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(command, underlying):
            return "Failed to launch `\(command)`: \(underlying.localizedDescription)"
        case let .timedOut(command, timeout):
            return "`\(command)` timed out after \(Int(timeout))s."
        case let .nonZeroExit(command, exitCode, stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "`\(command)` exited with code \(exitCode)."
            }
            return "`\(command)` exited with code \(exitCode): \(message)"
        }
    }
}

protocol CommandRunning {
    func run(
        _ command: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        environment: [String: String]?
    ) async throws -> CommandResult
}

struct CommandRunner: CommandRunning {
    func run(
        _ command: String,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        let executableURL = try await resolveExecutableURL(for: command)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL

            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let finishGate = LockedFinishGate()
            @Sendable func finish(_ result: Result<CommandResult, Error>) {
                guard finishGate.tryFinish() else { return }
                continuation.resume(with: result)
            }

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                finish(.success(CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(CommandRunnerError.launchFailed(command: command, underlying: error)))
                return
            }

            if let timeout {
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard process.isRunning else { return }
                    process.terminate()
                    finish(.failure(CommandRunnerError.timedOut(command: command, timeout: timeout)))
                }
            }
        }
    }

    private func resolveExecutableURL(for command: String) async throws -> URL {
        if command.contains("/") {
            return URL(fileURLWithPath: command)
        }

        if let shellResolvedPath = try await resolveUsingUserShell(command: command) {
            return URL(fileURLWithPath: shellResolvedPath)
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ]

        if let existingPath = fallbackPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: existingPath)
        }

        throw CommandRunnerError.launchFailed(
            command: command,
            underlying: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve executable path for `\(command)` from the user's shell environment."]
            )
        )
    }

    private func resolveUsingUserShell(command: String) async throws -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lic", "command -v \(command)"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard process.terminationStatus == 0, let stdout, !stdout.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: stdout)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CommandRunnerError.launchFailed(command: shell, underlying: error))
            }
        }
    }
}

private final class LockedFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didFinish = false

    nonisolated func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

