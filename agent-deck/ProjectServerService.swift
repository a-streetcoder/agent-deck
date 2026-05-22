import Darwin
import Foundation

// MARK: - Server command model

/// A runnable dev-server command detected for a project.
nonisolated struct ServerCommand: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let executable: String
    let arguments: [String]
    /// Best-effort port the server is expected to bind, used for clash
    /// pre-warning before the real port is parsed from output.
    let defaultPort: Int?
}

/// Detects runnable dev-server commands by probing a project's marker files.
nonisolated enum ServerCommandDetector {
    static func detect(at url: URL, fileManager: FileManager = .default) -> [ServerCommand] {
        func fileExists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent(name).path)
        }

        var commands: [ServerCommand] = []

        if fileExists("package.json") {
            commands += nodeCommands(packageJSONURL: url.appendingPathComponent("package.json"))
        }
        if fileExists("Cargo.toml") {
            commands.append(ServerCommand(
                id: "cargo-run",
                label: "cargo run",
                executable: "cargo",
                arguments: ["run"],
                defaultPort: nil
            ))
        }
        if fileExists("manage.py") {
            commands.append(ServerCommand(
                id: "django-runserver",
                label: "python3 manage.py runserver",
                executable: "python3",
                arguments: ["manage.py", "runserver"],
                defaultPort: 8000
            ))
        }
        if commands.isEmpty, fileExists("index.html") {
            commands.append(ServerCommand(
                id: "http-server",
                label: "python3 -m http.server",
                executable: "python3",
                arguments: ["-m", "http.server"],
                defaultPort: 8000
            ))
        }
        return commands
    }

    private static func nodeCommands(packageJSONURL: URL) -> [ServerCommand] {
        struct Manifest: Decodable {
            let scripts: [String: String]?
        }
        guard let data = try? Data(contentsOf: packageJSONURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              let scripts = manifest.scripts else {
            return []
        }
        var commands: [ServerCommand] = []
        for name in ["dev", "start", "serve"] {
            guard let body = scripts[name] else { continue }
            let label = (name == "start") ? "npm start" : "npm run \(name)"
            let arguments = (name == "start") ? ["start"] : ["run", name]
            commands.append(ServerCommand(
                id: "npm-\(name)",
                label: label,
                executable: "npm",
                arguments: arguments,
                defaultPort: nodeDefaultPort(scriptBody: body)
            ))
        }
        return commands
    }

    private static func nodeDefaultPort(scriptBody: String) -> Int? {
        let lower = scriptBody.lowercased()
        if let explicit = explicitPort(in: lower) {
            return explicit
        }
        if lower.contains("vite") { return 5173 }
        if lower.contains("astro") { return 4321 }
        if lower.contains("next") { return 3000 }
        if lower.contains("react-scripts") { return 3000 }
        if lower.contains("docusaurus") { return 3000 }
        if lower.contains("http-server") { return 8080 }
        return nil
    }

    private static func explicitPort(in scriptBody: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?:--port[ =]|-p )([0-9]{2,5})") else { return nil }
        let range = NSRange(scriptBody.startIndex..., in: scriptBody)
        guard let match = regex.firstMatch(in: scriptBody, range: range),
              match.numberOfRanges > 1,
              let portRange = Range(match.range(at: 1), in: scriptBody) else { return nil }
        return Int(scriptBody[portRange])
    }
}

/// Extracts the first loopback URL printed by a dev server's output line.
nonisolated enum ServerOutputParser {
    static func firstLocalURL(in line: String) -> URL? {
        let clean = stripANSI(line)
        let patterns = [
            "https?://[A-Za-z0-9._-]+:[0-9]{2,5}",
            "(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0):[0-9]{2,5}"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(clean.startIndex..., in: clean)
            guard let match = regex.firstMatch(in: clean, range: range),
                  let matchRange = Range(match.range, in: clean) else { continue }
            var text = String(clean[matchRange])
            if !text.lowercased().hasPrefix("http") {
                text = "http://" + text
            }
            guard var components = URLComponents(string: text), let host = components.host else { continue }
            guard host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" else { continue }
            if host == "0.0.0.0" {
                components.host = "localhost" // 0.0.0.0 is not browsable
            }
            if let url = components.url {
                return url
            }
        }
        return nil
    }

    private static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

// MARK: - Managed process

/// A long-running child process (a dev server). Unlike `PiAgentProcess` this is
/// not tied to the `pi` executable and has no stdin channel.
nonisolated final class ManagedProcess: @unchecked Sendable {
    private let process: Process
    private let stdoutReader: LineStreamReader
    private let stderrReader: LineStreamReader
    private let lock = NSLock()
    private var didTerminate = false
    private var didCleanupIO = false

    var isRunning: Bool { process.isRunning }

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        onStdoutLines: @escaping @Sendable ([String]) -> Void,
        onStderrLines: @escaping @Sendable ([String]) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.stdoutReader = LineStreamReader(handle: stdoutPipe.fileHandleForReading, callback: onStdoutLines)
        self.stderrReader = LineStreamReader(handle: stderrPipe.fileHandleForReading, callback: onStderrLines)
        self.process = process

        stdoutReader.start()
        stderrReader.start()

        process.terminationHandler = { [weak self] process in
            self?.cleanupIO()
            onTermination(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            cleanupIO()
            throw error
        }
    }

    deinit {
        terminate()
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = !didTerminate
        didTerminate = true
        lock.unlock()
        guard shouldTerminate else { return }

        if process.isRunning {
            Self.sendSignal(process, SIGTERM)
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [process] in
                if process.isRunning {
                    Self.sendSignal(process, SIGKILL)
                }
            }
        }
        cleanupIO()
    }

    /// Signals the child. When the child runs in its own process group the whole
    /// group is signalled so processes it spawned are not orphaned; otherwise
    /// only the direct child is signalled (npm grandchildren sharing our group
    /// remain a known limitation).
    private static func sendSignal(_ process: Process, _ signalNumber: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let childGroup = getpgid(pid)
        let ownGroup = getpgid(0)
        if childGroup > 0, childGroup != ownGroup {
            kill(-childGroup, signalNumber)
        } else {
            kill(pid, signalNumber)
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
}

// MARK: - Running server state

nonisolated enum ServerStatus: Equatable, Sendable {
    case starting
    case running
    case stopped
    case crashed(Int32)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        case .stopped, .crashed, .failed: return false
        }
    }
}

@MainActor
@Observable
final class RunningServer: Identifiable {
    let id = UUID()
    let projectPath: String
    let projectName: String
    let command: ServerCommand
    let startedAt: Date
    var status: ServerStatus = .starting
    var detectedURL: URL?
    var port: Int?
    @ObservationIgnored fileprivate var process: ManagedProcess?

    init(projectPath: String, projectName: String, command: ServerCommand) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.command = command
        self.startedAt = Date()
        self.port = command.defaultPort
    }
}

// MARK: - Service

/// Owns the lifecycle of project dev servers started from the Pi Agent toolbar.
@MainActor
@Observable
final class ProjectServerService {
    private(set) var servers: [RunningServer] = []
    /// Cached dev-server command detection per project path. A `nil` entry (key
    /// absent) means detection has not completed yet; an empty array means the
    /// project has no runnable dev server. Kept off the render hot path so the
    /// toolbar can decide visibility without per-frame filesystem I/O.
    private(set) var detectedCommandsByPath: [String: [ServerCommand]] = [:]
    @ObservationIgnored private let commandRunner = CommandRunner()

    func servers(forProjectPath path: String) -> [RunningServer] {
        servers.filter { $0.projectPath == path }
    }

    /// Whether `path` is known to have at least one runnable dev-server command.
    /// `nil` until `refreshDetectedCommands(forProjectPath:)` has completed for it.
    func hasDetectedCommands(forProjectPath path: String) -> Bool? {
        detectedCommandsByPath[path].map { !$0.isEmpty }
    }

    /// Runs marker-file detection for `path` off the main actor and caches the
    /// result. Cheap to call repeatedly — callers debounce by triggering on a
    /// project-path change — so a newly added dev script is picked up on the
    /// next selection.
    func refreshDetectedCommands(forProjectPath path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        Task.detached(priority: .utility) { [weak self] in
            let commands = ServerCommandDetector.detect(at: url)
            await MainActor.run {
                self?.detectedCommandsByPath[path] = commands
            }
        }
    }

    /// The most recent server tracked for a project, regardless of status, so a
    /// crashed/stopped server stays visible in the popover.
    func currentServer(forProjectPath path: String) -> RunningServer? {
        servers.last { $0.projectPath == path }
    }

    func activeServer(forProjectPath path: String) -> RunningServer? {
        servers.last { $0.projectPath == path && $0.status.isActive }
    }

    /// Other projects' active servers that occupy `predictedPort`.
    func conflictingServers(predictedPort: Int?, excludingProjectPath path: String) -> [RunningServer] {
        guard let predictedPort else { return [] }
        return servers.filter {
            $0.projectPath != path && $0.status.isActive && $0.port == predictedPort
        }
    }

    @discardableResult
    func start(command: ServerCommand, projectPath: String, projectName: String) -> RunningServer {
        let server = RunningServer(projectPath: projectPath, projectName: projectName, command: command)
        servers.append(server)
        launch(server)
        return server
    }

    func stop(_ server: RunningServer) {
        if server.status.isActive {
            server.status = .stopped
        }
        server.process?.terminate()
        server.process = nil
    }

    func restart(_ server: RunningServer) {
        let command = server.command
        let projectPath = server.projectPath
        let projectName = server.projectName
        stop(server)
        servers.removeAll { $0.id == server.id }
        // Give the old process a moment to release its port before relaunching.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.start(command: command, projectPath: projectPath, projectName: projectName)
        }
    }

    func remove(_ server: RunningServer) {
        stop(server)
        servers.removeAll { $0.id == server.id }
    }

    func terminateAll() {
        for server in servers {
            server.process?.terminate()
            server.process = nil
        }
        servers.removeAll()
    }

    private func launch(_ server: RunningServer) {
        let serverID = server.id
        let command = server.command
        let projectPath = server.projectPath
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executableURL = try await self.commandRunner.resolveExecutableURL(for: command.executable)
                // The server may have been stopped while the executable resolved.
                guard let server = self.servers.first(where: { $0.id == serverID }),
                      server.status == .starting else { return }
                let environment = CommandRunner.processEnvironment(merging: nil, executableURL: executableURL)
                let process = try ManagedProcess(
                    executableURL: executableURL,
                    arguments: command.arguments,
                    currentDirectoryURL: URL(fileURLWithPath: projectPath, isDirectory: true),
                    environment: environment,
                    onStdoutLines: { [weak self] lines in
                        Task { @MainActor in self?.handleOutput(lines, serverID: serverID) }
                    },
                    onStderrLines: { [weak self] lines in
                        Task { @MainActor in self?.handleOutput(lines, serverID: serverID) }
                    },
                    onTermination: { [weak self] exitCode in
                        Task { @MainActor in self?.handleTermination(exitCode, serverID: serverID) }
                    }
                )
                server.process = process
                server.status = .running
            } catch {
                if let server = self.servers.first(where: { $0.id == serverID }) {
                    server.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handleOutput(_ lines: [String], serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }), server.detectedURL == nil else { return }
        for line in lines {
            if let url = ServerOutputParser.firstLocalURL(in: line) {
                server.detectedURL = url
                if let port = url.port {
                    server.port = port
                }
                break
            }
        }
    }

    private func handleTermination(_ exitCode: Int32, serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        server.process = nil
        switch server.status {
        case .stopped, .failed, .crashed:
            break // already finalized (e.g. an explicit stop)
        case .starting, .running:
            server.status = (exitCode == 0) ? .stopped : .crashed(exitCode)
        }
    }
}
