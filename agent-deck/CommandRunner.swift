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
    private static let executableResolutionLock = NSLock()
    nonisolated(unsafe) private static var executableResolutionCache: [String: URL] = [:]

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
            process.environment = Self.processEnvironment(merging: environment, executableURL: executableURL)

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

    func resolveExecutableURL(for command: String) async throws -> URL {
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

        let cacheKey = Self.executableCacheKey(for: command)
        if let cached = Self.cachedExecutableURL(for: cacheKey), FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }

        let resolvedURL: URL?
        if let shellResolvedPath = try? await resolveUsingUserShell(command: command) {
            resolvedURL = URL(fileURLWithPath: shellResolvedPath)
        } else if let pathResolved = Self.resolveExecutableInPATH(command) {
            resolvedURL = URL(fileURLWithPath: pathResolved)
        } else {
            resolvedURL = nil
        }

        if let resolvedURL {
            Self.cacheExecutableURL(resolvedURL, for: cacheKey)
            return resolvedURL
        }

        throw CommandRunnerError.launchFailed(
            command: command,
            underlying: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "Unable to resolve executable path for `\(command)` from PATH or the user's shell environment."]
            )
        )
    }

    private static func executableCacheKey(for command: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        return [
            command,
            environment["SHELL"] ?? "",
            environment["PATH"] ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func cachedExecutableURL(for cacheKey: String) -> URL? {
        executableResolutionLock.lock()
        defer { executableResolutionLock.unlock() }
        return executableResolutionCache[cacheKey]
    }

    private static func cacheExecutableURL(_ url: URL, for cacheKey: String) {
        executableResolutionLock.lock()
        executableResolutionCache[cacheKey] = url
        executableResolutionLock.unlock()
    }

    private static func resolveExecutableInPATH(_ command: String) -> String? {
        let environment = processEnvironment(merging: nil)
        let path = environment["PATH"] ?? ""
        var checked: Set<String> = []
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            guard checked.insert(candidate).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
            let finishGate = LockedFinishGate()

            @Sendable func finish(_ value: String?) {
                guard finishGate.tryFinish() else { return }
                outputCollector.stop()
                continuation.resume(returning: value)
            }

            process.terminationHandler = { process in
                outputCollector.drainRemainingData()
                let output = outputCollector.output()
                let stdout = output.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard process.terminationStatus == 0, !stdout.isEmpty else {
                    finish(nil)
                    return
                }

                finish(stdout)
            }

            do {
                outputCollector.start()
                try process.run()
            } catch {
                outputCollector.stop()
                continuation.resume(throwing: CommandRunnerError.launchFailed(command: shell, underlying: error))
                return
            }

            Task.detached {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard process.isRunning else { return }
                process.terminate()
                finish(nil)
            }
        }
    }

    static func processEnvironment(merging environment: [String: String]?, executableURL: URL? = nil) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = merged["PATH"], !existingPath.isEmpty {
            let pathParts = existingPath.split(separator: ":").map(String.init)
            let additions = defaultPath.split(separator: ":").map(String.init).filter { !pathParts.contains($0) }
            if !additions.isEmpty {
                merged["PATH"] = ([existingPath] + additions).joined(separator: ":")
            }
        } else {
            merged["PATH"] = defaultPath
        }
        if let environment {
            merged.merge(environment) { _, new in new }
        }
        if let executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent().path
            let path = merged["PATH"] ?? defaultPath
            let pathParts = path.split(separator: ":").map(String.init)
            if !pathParts.contains(executableDirectory) {
                merged["PATH"] = ([executableDirectory] + pathParts).joined(separator: ":")
            }
        }
        return merged
    }
}

private final class LockedProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    nonisolated(unsafe) private var stdoutData = Data()
    nonisolated(unsafe) private var stderrData = Data()
    nonisolated(unsafe) private var didStop = false

    nonisolated init(stdout: FileHandle, stderr: FileHandle) {
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    nonisolated func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: true)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: false)
        }
    }

    nonisolated func drainRemainingData() {
        guard !isStopped else { return }
        append(stdoutHandle.availableData, toStdout: true)
        append(stderrHandle.availableData, toStdout: false)
    }

    nonisolated func stop() {
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

    nonisolated func output() -> (stdout: String, stderr: String) {
        lock.lock()
        let stdout = stdoutData
        let stderr = stderrData
        lock.unlock()
        return (
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    private nonisolated func append(_ data: Data, toStdout: Bool) {
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

    private nonisolated var isStopped: Bool {
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
