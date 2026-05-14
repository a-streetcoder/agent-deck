import Foundation

nonisolated final class PiAgentProcess: @unchecked Sendable {
    struct Configuration {
        var arguments: [String]
        var currentDirectoryURL: URL
        var environment: [String: String] = [:]
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
    private static let executableCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedExecutable: (key: String, url: URL)?

    init(configuration: Configuration, onStdoutLines: @escaping @Sendable ([String]) -> Void, onStderrLines: @escaping @Sendable ([String]) -> Void, onTermination: @escaping @Sendable (Int32) -> Void) throws {
        let executable = try Self.resolvePiExecutable()
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
            self?.cleanupIO()
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
        cleanupIO()
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

    private static func resolvePiExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let cacheKey = executableCacheKey(environment: environment)
        executableCacheLock.lock()
        if let cachedExecutable, cachedExecutable.key == cacheKey, FileManager.default.isExecutableFile(atPath: cachedExecutable.url.path) {
            executableCacheLock.unlock()
            return cachedExecutable.url
        }
        executableCacheLock.unlock()

        let resolved = try resolvePiExecutableUncached(environment: environment)
        executableCacheLock.lock()
        cachedExecutable = (cacheKey, resolved)
        executableCacheLock.unlock()
        return resolved
    }

    private static func resolvePiExecutableUncached(environment: [String: String]) throws -> URL {
        for key in ["AGENT_DECK_PI_PATH", "PI_CLI_PATH"] {
            if let raw = environment[key], let url = executableURL(from: raw) {
                return url
            }
        }

        if let pathResolved = resolveExecutableInPATH("pi", environment: environment) {
            return pathResolved
        }

        if let shellResolved = resolveUsingShell("pi") {
            return shellResolved
        }

        let candidates = commonPiCandidates()
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        throw ProcessError.executableNotFound
    }

    private static func executableCacheKey(environment: [String: String]) -> String {
        [
            environment["AGENT_DECK_PI_PATH"] ?? "",
            environment["PI_CLI_PATH"] ?? "",
            environment["SHELL"] ?? "",
            environment["PATH"] ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func executableURL(from raw: String) -> URL? {
        let expanded = NSString(string: raw).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        return nil
    }

    private static func resolveExecutableInPATH(_ command: String, environment: [String: String]) -> URL? {
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let path = [environment["PATH"], defaultPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        var checked: Set<String> = []
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            guard checked.insert(candidate).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func resolveUsingShell(_ command: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
            if semaphore.wait(timeout: .now() + 5) == .timedOut {
                process.terminate()
                _ = semaphore.wait(timeout: .now() + 1)
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private static func commonPiCandidates() -> [URL] {
        var paths = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi"
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.pi/agent/bin/pi",
            "\(home)/.volta/bin/pi",
            "\(home)/.local/bin/pi",
            "\(home)/.npm-global/bin/pi",
            "\(home)/.npm/bin/pi",
            "\(home)/.nvm/versions/node/current/bin/pi"
        ])
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths.append(contentsOf: versions.map { $0.appendingPathComponent("bin/pi").path })
        }
        return paths.map(URL.init(fileURLWithPath:))
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

private nonisolated final class LineStreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let callback: @Sendable ([String]) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var isStopped = false

    init(handle: FileHandle, callback: @escaping @Sendable ([String]) -> Void) {
        self.handle = handle
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
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
        append(handle.availableData)
        flushBufferedLine()
        try? handle.close()
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isStopped || !data.isEmpty else {
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
