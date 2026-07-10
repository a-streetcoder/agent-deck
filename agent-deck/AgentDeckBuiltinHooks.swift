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
        var runID: UUID? = nil
        /// Test-only seam for the narrow registration/install-to-run interleaving.
        var onProcessPrepared: (() async -> Void)? = nil
    }

    private final class ValidationProcessHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var finished = false
        private var cancelled = false
        private var timedOut = false
        private var continuation: CheckedContinuation<Void, Never>?

        func install(_ process: Process) {
            let shouldCancel = lock.withLock { () -> Bool in
                self.process = process
                return cancelled
            }
            if shouldCancel { cancelProcess(process) }
        }

        func markFinished() {
            lock.lock()
            finished = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }

        func waitUntilFinished() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    if finished || cancelled { return true }
                    self.continuation = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }

        var hasFinished: Bool { lock.withLock { finished } }
        var isCancelled: Bool { lock.withLock { cancelled } }
        var didTimeOut: Bool { lock.withLock { timedOut } }

        func timeout() {
            lock.withLock { timedOut = true }
            cancel()
        }

        private func cancelProcess(_ process: Process) {
            guard process.isRunning else { return }
            let childKiller = Process()
            childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            childKiller.arguments = ["-TERM", "-P", String(process.processIdentifier)]
            try? childKiller.run()
            process.terminate()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = process
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            guard let process, process.isRunning else {
                continuation?.resume()
                return
            }
            cancelProcess(process)
            continuation?.resume()
        }
    }

    private actor ValidationProcessRegistry {
        private var holders: [UUID: ValidationProcessHolder] = [:]
        private var cancelledRunIDs: Set<UUID> = []

        /// Returns true when a stop request arrived before registration.
        func insert(_ holder: ValidationProcessHolder, for runID: UUID) -> Bool {
            guard !cancelledRunIDs.contains(runID) else { return true }
            holders[runID] = holder
            return false
        }
        func remove(_ runID: UUID, holder: ValidationProcessHolder) {
            guard holders[runID] === holder else { return }
            holders.removeValue(forKey: runID)
        }
        func cancel(_ runID: UUID) {
            cancelledRunIDs.insert(runID)
            holders[runID]?.cancel()
        }
    }

    private static let validationRegistry = ValidationProcessRegistry()

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

    static func cancelValidation(runID: UUID) async {
        await validationRegistry.cancel(runID)
    }

    /// Async variant for live loops. It never blocks the main actor and kills the
    /// shell (and direct children where possible) when the loop is stopped.
    static func runValidationAsync(_ context: ValidationContext) async -> LoopValidationResult {
        let startedAt = Date()
        let stdoutURL = context.outputDirectory.appendingPathComponent("\(UUID().uuidString)-stdout.txt")
        let stderrURL = context.outputDirectory.appendingPathComponent("\(UUID().uuidString)-stderr.txt")
        let holder = ValidationProcessHolder()
        if let runID = context.runID,
           await validationRegistry.insert(holder, for: runID) {
            return LoopValidationResult(command: context.command, workingDirectory: context.workingDirectory?.path, exitCode: nil, duration: Date().timeIntervalSince(startedAt), stdout: "", stderr: "Validation cancelled before it started.")
        }
        defer {
            if let runID = context.runID {
                Task { await validationRegistry.remove(runID, holder: holder) }
            }
        }

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
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", context.command]
            process.currentDirectoryURL = context.workingDirectory
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            process.terminationHandler = { _ in holder.markFinished() }
            holder.install(process)
            if let onProcessPrepared = context.onProcessPrepared {
                await onProcessPrepared()
            }
            try process.run()
            // A stop can arrive after registration/install but before `run()`.
            // Re-check after spawning so that interleaving cannot launch work.
            if holder.isCancelled {
                holder.cancel()
                return LoopValidationResult(command: context.command, workingDirectory: context.workingDirectory?.path, exitCode: nil, duration: Date().timeIntervalSince(startedAt), stdout: "", stderr: "Validation cancelled.", stdoutPath: stdoutURL.path, stderrPath: stderrURL.path)
            }

            let timeoutWorkItem = DispatchWorkItem { holder.timeout() }
            DispatchQueue.global().asyncAfter(deadline: .now() + context.timeout, execute: timeoutWorkItem)
            await withTaskCancellationHandler(operation: {
                await holder.waitUntilFinished()
            }, onCancel: {
                holder.cancel()
            })
            timeoutWorkItem.cancel()
            let completedBeforeTimeout = holder.hasFinished && !holder.didTimeOut && !holder.isCancelled
            if !completedBeforeTimeout || Task.isCancelled {
                holder.cancel()
            }

            var stderr = cappedText(at: stderrURL)
            if holder.didTimeOut {
                let seconds = Int(context.timeout)
                stderr += stderr.isEmpty ? "Validation command timed out after \(seconds) seconds." : "\nValidation command timed out after \(seconds) seconds."
            } else if !completedBeforeTimeout || Task.isCancelled || holder.isCancelled {
                stderr += stderr.isEmpty ? "Validation cancelled." : "\nValidation cancelled."
            }
            return LoopValidationResult(
                command: context.command,
                workingDirectory: context.workingDirectory?.path,
                exitCode: completedBeforeTimeout && !Task.isCancelled ? Int(process.terminationStatus) : nil,
                duration: Date().timeIntervalSince(startedAt),
                stdout: cappedText(at: stdoutURL),
                stderr: stderr,
                stdoutPath: stdoutURL.path,
                stderrPath: stderrURL.path
            )
        } catch {
            return LoopValidationResult(command: context.command, workingDirectory: context.workingDirectory?.path, exitCode: nil, duration: Date().timeIntervalSince(startedAt), stdout: "", stderr: error.localizedDescription)
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
