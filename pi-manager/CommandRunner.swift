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

protocol CommandRunning: Sendable {
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
            let outputCollector = LockedProcessOutputCollector(stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading)
            @Sendable func finish(_ result: Result<CommandResult, Error>) {
                guard finishGate.tryFinish() else { return }
                outputCollector.stop()
                continuation.resume(with: result)
            }

            process.terminationHandler = { process in
                outputCollector.drainRemainingData()
                let output = outputCollector.output()
                finish(.success(CommandResult(stdout: output.stdout, stderr: output.stderr, exitCode: process.terminationStatus)))
            }

            do {
                outputCollector.start()
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

        guard isSafeExecutableName(command) else {
            throw CommandRunnerError.launchFailed(
                command: command,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EINVAL),
                    userInfo: [NSLocalizedDescriptionKey: "Executable names may contain only letters, numbers, dots, underscores, plus signs, and hyphens."]
                )
            )
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

    private func isSafeExecutableName(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        return command.unicodeScalars.allSatisfy { allowed.contains($0) }
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
            let outputCollector = LockedProcessOutputCollector(stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading)

            process.terminationHandler = { process in
                outputCollector.drainRemainingData()
                let output = outputCollector.output()
                outputCollector.stop()
                let stdout = output.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard process.terminationStatus == 0, !stdout.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: stdout)
            }

            do {
                outputCollector.start()
                try process.run()
            } catch {
                outputCollector.stop()
                continuation.resume(throwing: CommandRunnerError.launchFailed(command: shell, underlying: error))
            }
        }
    }
}

private final class LockedProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var stdoutData = Data()
    private var stderrData = Data()
    private var didStop = false

    init(stdout: FileHandle, stderr: FileHandle) {
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: true)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: false)
        }
    }

    func drainRemainingData() {
        guard !isStopped else { return }
        append(stdoutHandle.availableData, toStdout: true)
        append(stderrHandle.availableData, toStdout: false)
    }

    func stop() {
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        didStop = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func output() -> (stdout: String, stderr: String) {
        lock.lock()
        let stdout = stdoutData
        let stderr = stderrData
        lock.unlock()
        return (
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    private func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        if toStdout {
            stdoutData.append(data)
        } else {
            stderrData.append(data)
        }
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        let value = didStop
        lock.unlock()
        return value
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
