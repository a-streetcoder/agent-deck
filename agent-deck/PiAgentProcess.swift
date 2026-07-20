import Darwin
import Foundation

nonisolated final class PiAgentProcess: @unchecked Sendable {
    struct Configuration {
        var arguments: [String]
        var currentDirectoryURL: URL
        var environment: [String: String] = [:]
        /// Executable to launch. When `nil`, the `pi` binary is resolved. Set
        /// it to run a different tool (e.g. `node` for the OAuth login bridge)
        /// over the same streaming stdin/stdout plumbing.
        var executableURL: URL? = nil
    }

    enum ProcessError: LocalizedError {
        case executableNotFound
        case launchFailed(Error)
        case stdinUnavailable

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "Could not find pi. Install it with `npm install -g @earendil-works/pi-coding-agent` or configure AGENT_DECK_PI_PATH."
            case let .launchFailed(error):
                return "Failed to launch pi: \(error.localizedDescription)"
            case .stdinUnavailable:
                return "Pi process stdin is unavailable."
            }
        }
    }

    let launchCommand: String
    private let process: Process
    private let stdin: FileHandle
    private let stdoutReader: LineStreamReader
    private let stderrReader: LineStreamReader
    private let writeQueue = DispatchQueue(label: "agent-deck.agent.stdin")
    private let lock = NSLock()
    private var didTerminate = false
    private var didCleanupIO = false

    init(configuration: Configuration, onStdoutLines: @escaping @Sendable ([String]) -> Void, onStderrLines: @escaping @Sendable ([String]) -> Void, onTermination: @escaping @Sendable (Int32) -> Void) throws {
        let executable = try configuration.executableURL ?? Self.resolvePiExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.environment = Self.processEnvironment(extra: configuration.environment, executableURL: executable)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutReader = LineStreamReader(handle: stdoutPipe.fileHandleForReading, callback: onStdoutLines)
        self.stderrReader = LineStreamReader(handle: stderrPipe.fileHandleForReading, callback: onStderrLines)
        self.process = process
        self.launchCommand = ([executable.path] + configuration.arguments).map(Self.shellEscape).joined(separator: " ")

        stdoutReader.start()
        stderrReader.start()

        process.terminationHandler = { [weak self] process in
            self?.finishIOAfterProcessExit()
            onTermination(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error)
        }
    }

    deinit {
        terminate()
    }

    var isRunning: Bool { process.isRunning }

    func writeJSONLine(_ json: String) {
        writeQueue.async { [stdin] in
            guard let data = (json + "\n").data(using: .utf8) else { return }
            do {
                try stdin.write(contentsOf: data)
            } catch {
                // The reader/termination path will surface process failure.
            }
        }
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = !didTerminate
        didTerminate = true
        lock.unlock()
        guard shouldTerminate else { return }

        writeQueue.async { [stdin, process] in
            try? stdin.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }
        // cleanupIO closes pipes and tears down the readers. The terminationHandler
        // also runs it once the child actually exits — both paths are idempotent.
        // Run it off the caller's thread so a slow close() can never freeze main.
        DispatchQueue.global().async { [weak self] in
            self?.cleanupIO()
        }
    }

    private func cleanupIO() {
        lock.lock()
        let shouldCleanup = !didCleanupIO
        didCleanupIO = true
        lock.unlock()
        guard shouldCleanup else { return }

        stdoutReader.stop()
        stderrReader.stop()
    }

    /// Once the process has exited, drain bytes left in its pipes before reporting
    /// termination so short-lived helpers cannot lose their final diagnostic line.
    private func finishIOAfterProcessExit() {
        lock.lock()
        let shouldCleanup = !didCleanupIO
        didCleanupIO = true
        lock.unlock()
        guard shouldCleanup else { return }

        stdoutReader.finishAfterProcessExit()
        stderrReader.finishAfterProcessExit()
    }

    private static func resolvePiExecutable() throws -> URL {
        guard let url = PiExecutableResolver().resolve() else {
            throw ProcessError.executableNotFound
        }
        return url
    }

    private static func processEnvironment(extra: [String: String], executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        var pathParts = [executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let existing = environment["PATH"] {
            pathParts.append(existing)
        }
        environment["PATH"] = pathParts.joined(separator: ":")
        return environment
    }

    private nonisolated static func shellEscape(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.:,=".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Buffers a `FileHandle`'s bytes and emits complete, non-empty lines.
/// Shared by `PiAgentProcess` and `ManagedProcess`.
nonisolated final class LineStreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let callback: @Sendable ([String]) -> Void
    private let lock = NSCondition()
    private var buffer = Data()
    private var isStopped = false
    private var isFinishing = false
    private var activeReads = 0

    init(handle: FileHandle, callback: @escaping @Sendable ([String]) -> Void) {
        self.handle = handle
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle)
        }
    }

    private func consumeAvailableData(from handle: FileHandle) {
        lock.lock()
        guard !isStopped, !isFinishing else { lock.unlock(); return }
        activeReads += 1
        lock.unlock()

        let data = handle.availableData
        append(data)

        lock.lock()
        activeReads -= 1
        lock.broadcast()
        lock.unlock()
    }

    func finishAfterProcessExit() {
        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        isFinishing = true
        handle.readabilityHandler = nil
        while activeReads > 0 { lock.wait() }
        lock.unlock()

        // Drain only bytes already available. `readToEnd()` can hang when a
        // descendant inherited the pipe after the direct child exited.
        var availableBytes: Int32 = 0
        let bytesAvailableRequest = UInt(0x4004_667F) // Darwin FIONREAD
        if ioctl(handle.fileDescriptor, bytesAvailableRequest, &availableBytes) == 0,
           availableBytes > 0,
           let remaining = try? handle.read(upToCount: Int(availableBytes)),
           !remaining.isEmpty {
            append(remaining)
        }
        stop()
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()

        handle.readabilityHandler = nil
        flushBufferedLine()
        try? handle.close()
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var lines: [String] = []
        var lineStart = buffer.startIndex
        var index = lineStart
        while index < buffer.endIndex {
            guard buffer[index] == 0x0A else {
                index = buffer.index(after: index)
                continue
            }
            let lineData = buffer[lineStart..<index]
            if let line = Self.normalizedLine(from: lineData) {
                lines.append(line)
            }
            index = buffer.index(after: index)
            lineStart = index
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(..<lineStart)
        }
        lock.unlock()

        if !lines.isEmpty {
            callback(lines)
        }
    }

    private func flushBufferedLine() {
        lock.lock()
        let line = buffer.isEmpty ? nil : Self.normalizedLine(from: buffer)
        buffer.removeAll()
        lock.unlock()
        if let line {
            callback([line])
        }
    }

    private static func normalizedLine(from data: Data) -> String? {
        var line = String(data: data, encoding: .utf8) ?? ""
        if line.hasSuffix("\r") { line.removeLast() }
        return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : line
    }
}
