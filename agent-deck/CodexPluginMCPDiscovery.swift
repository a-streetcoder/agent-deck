import Foundation

/// Read-only discovery for the explicitly supported Codex Computer Use plugin.
/// It deliberately does not enumerate arbitrary plugin MCP servers.
nonisolated struct CodexPluginMCPDiscovery: Sendable {
    static let computerUsePluginID = "computer-use@openai-bundled"
    static let maximumOutputBytes = 1_000_000
    static let commandTimeout: TimeInterval = 5

    struct Resource: Hashable, Sendable, Identifiable {
        let pluginID: String                 // Stable; never contains the temporary root.
        let serverName: String
        let version: String?
        let provenance: Provenance
        let config: MCPServerConfig           // Ephemeral, resolved command/cwd.
        let sourcePath: String                // Read-only .mcp.json path.
        var id: String { "\(pluginID):\(serverName)" }
    }

    struct Provenance: Hashable, Sendable {
        let marketplace: String
        let sourceType: String
        let source: String
    }

    enum Diagnostic: Hashable, Sendable, LocalizedError {
        case executableNotFound
        case commandFailed(String)
        case timedOut
        case outputTooLarge
        case malformedPluginList
        case pluginNotInstalled
        case pluginDisabled
        case invalidPluginRoot(String)
        case missingManifest
        case invalidManifest
        case missingMCPDefinition
        case invalidMCPDefinition(String)
        case noUsableServer

        var errorDescription: String? {
            switch self {
            case .executableNotFound: return "Codex was not found. Install Codex or configure AGENT_DECK_CODEX_PATH."
            case let .commandFailed(message): return "Codex could not list plugins: \(message)"
            case .timedOut: return "Codex plugin discovery timed out. Try again after Codex is idle."
            case .outputTooLarge: return "Codex plugin discovery produced too much output."
            case .malformedPluginList: return "Codex returned an unreadable plugin list."
            case .pluginNotInstalled: return "The Codex Computer Use plugin is not installed."
            case .pluginDisabled: return "The Codex Computer Use plugin is installed but disabled."
            case let .invalidPluginRoot(path): return "Codex reported an invalid Computer Use plugin root: \(path)"
            case .missingManifest: return "The Computer Use plugin manifest is missing."
            case .invalidManifest: return "The Computer Use plugin manifest does not match its Codex identity."
            case .missingMCPDefinition: return "The Computer Use plugin does not provide .mcp.json."
            case let .invalidMCPDefinition(message): return "The Computer Use MCP definition is invalid: \(message)"
            case .noUsableServer: return "The Computer Use plugin has no usable stdio MCP server."
            }
        }
    }

    struct Result: Hashable, Sendable {
        let resources: [Resource]
        let diagnostics: [Diagnostic]
    }

    private let runner: any CodexPluginListRunning
    private let executableResolver: any CodexExecutableResolving
    private let fileSystem: FileSystem

    init(runner: any CodexPluginListRunning = CodexPluginListProcessRunner(),
         executableResolver: any CodexExecutableResolving = CodexExecutableResolver(),
         fileManager: FileManager = .default) {
        self.runner = runner
        self.executableResolver = executableResolver
        self.fileSystem = FileSystem(fileManager)
    }

    func discover() async -> Result {
        guard let executable = executableResolver.resolve() else {
            return Result(resources: [], diagnostics: [.executableNotFound])
        }
        let output: String
        do {
            output = try await runner.run(executable: executable, arguments: ["plugin", "list", "--json"], timeout: Self.commandTimeout, maximumOutputBytes: Self.maximumOutputBytes)
        } catch let error as CodexPluginListRunnerError {
            return Result(resources: [], diagnostics: [error.diagnostic])
        } catch {
            return Result(resources: [], diagnostics: [.commandFailed(error.localizedDescription)])
        }
        guard let list = try? JSONDecoder().decode(PluginList.self, from: Data(output.utf8)) else {
            return Result(resources: [], diagnostics: [.malformedPluginList])
        }
        guard let plugin = list.installed.first(where: { $0.pluginID == Self.computerUsePluginID && $0.installed }) else {
            return Result(resources: [], diagnostics: [.pluginNotInstalled])
        }
        guard plugin.enabled else { return Result(resources: [], diagnostics: [.pluginDisabled]) }
        guard plugin.source.kind == "local", let rawRoot = plugin.source.path, !rawRoot.isEmpty else {
            return Result(resources: [], diagnostics: [.invalidPluginRoot(plugin.source.path ?? "unknown")])
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard fileSystem.fileManager.fileExists(atPath: root.path), isDirectory(root) else {
            return Result(resources: [], diagnostics: [.invalidPluginRoot(root.path)])
        }
        let manifest = root.appendingPathComponent(".codex-plugin/plugin.json")
        guard contained(manifest, in: root), fileSystem.fileManager.fileExists(atPath: manifest.path) else {
            return Result(resources: [], diagnostics: [.missingManifest])
        }
        guard let manifestData = try? Data(contentsOf: manifest),
              let manifestValue = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifestValue["name"] as? String == "computer-use" else {
            return Result(resources: [], diagnostics: [.invalidManifest])
        }
        let mcpURL = root.appendingPathComponent(".mcp.json")
        guard contained(mcpURL, in: root), fileSystem.fileManager.fileExists(atPath: mcpURL.path) else {
            return Result(resources: [], diagnostics: [.missingMCPDefinition])
        }
        guard let data = try? Data(contentsOf: mcpURL), let file = try? JSONDecoder().decode(MCPServersFile.self, from: data) else {
            return Result(resources: [], diagnostics: [.invalidMCPDefinition("it is not valid JSON")])
        }
        var resources: [Resource] = []
        var errors: [Diagnostic] = []
        for (name, rawConfig) in (file.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch resolve(rawConfig, root: root) {
            case let .success(config):
                resources.append(Resource(pluginID: plugin.pluginID, serverName: name, version: plugin.version, provenance: .init(marketplace: plugin.marketplaceName, sourceType: plugin.source.kind, source: root.path), config: config, sourcePath: mcpURL.path))
            case let .failure(diagnostic): errors.append(diagnostic)
            }
        }
        return Result(resources: resources, diagnostics: resources.isEmpty ? (errors.isEmpty ? [.noUsableServer] : errors) : errors)
    }

    private func resolve(_ raw: MCPServerConfig, root: URL) -> Swift.Result<MCPServerConfig, Diagnostic> {
        guard raw.resolvedTransport == .stdio, let command = raw.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .failure(.invalidMCPDefinition("a server must use stdio with a command"))
        }
        guard let resolvedCommand = resolveCommand(command, root: root) else {
            return .failure(.invalidMCPDefinition("helper executable is missing or outside the plugin root"))
        }
        var config = raw
        config.command = resolvedCommand.path
        if let cwd = raw.cwd, !cwd.isEmpty {
            guard let resolvedCWD = resolvePath(cwd, root: root), isDirectory(resolvedCWD) else {
                return .failure(.invalidMCPDefinition("working directory is missing or outside the plugin root"))
            }
            config.cwd = resolvedCWD.path
        } else { config.cwd = root.path }
        return .success(config)
    }

    private func resolveCommand(_ command: String, root: URL) -> URL? {
        // This adapter only trusts a helper shipped inside the reported plugin root.
        guard command.contains("/") else { return nil }
        return resolvePath(command, root: root).flatMap { fileSystem.fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private func resolvePath(_ raw: String, root: URL) -> URL? {
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return contained(resolved, in: root) ? resolved : nil
    }

    private func contained(_ child: URL, in root: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }

    private func isDirectory(_ url: URL) -> Bool { var value: ObjCBool = false; return fileSystem.fileManager.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue }

    private struct PluginList: Decodable { let installed: [Plugin] }
    private struct Plugin: Decodable {
        let pluginID: String; let marketplaceName: String; let version: String?; let installed: Bool; let enabled: Bool; let source: Source
        enum CodingKeys: String, CodingKey { case pluginID = "pluginId", marketplaceName, version, installed, enabled, source, path }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            pluginID = try values.decode(String.self, forKey: .pluginID)
            marketplaceName = try values.decode(String.self, forKey: .marketplaceName)
            version = try values.decodeIfPresent(String.self, forKey: .version)
            installed = try values.decode(Bool.self, forKey: .installed)
            enabled = try values.decode(Bool.self, forKey: .enabled)
            if let nested = try? values.decode(NestedSource.self, forKey: .source) {
                source = Source(kind: nested.kind, path: nested.path)
            } else {
                source = Source(kind: try values.decode(String.self, forKey: .source), path: try values.decodeIfPresent(String.self, forKey: .path))
            }
        }
    }
    private struct NestedSource: Decodable { let kind: String; let path: String?; enum CodingKeys: String, CodingKey { case kind = "source", path } }
    private struct Source { let kind: String; let path: String? }

}

nonisolated protocol CodexExecutableResolving: Sendable { func resolve() -> URL? }

/// Uses the same explicit-override, PATH, then standard-location policy as PiExecutableResolver.
nonisolated struct CodexExecutableResolver: CodexExecutableResolving {
    private let environment: @Sendable () -> [String: String]
    private let candidates: @Sendable () -> [URL]

    init(environment: @Sendable @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
         candidates: @Sendable @escaping () -> [URL] = { CodexExecutableResolver.knownCandidates() }) {
        self.environment = environment
        self.candidates = candidates
    }

    func resolve() -> URL? {
        let environment = environment()
        for key in ["AGENT_DECK_CODEX_PATH", "CODEX_CLI_PATH"] {
            if let value = environment[key] {
                let path = NSString(string: value).expandingTildeInPath
                if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        let pathDirectories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let pathMatch = pathDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        return pathMatch ?? candidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func knownCandidates() -> [URL] {
        ["/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex", "/bin/codex"].map(URL.init(fileURLWithPath:))
    }
}

nonisolated protocol CodexPluginListRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> String
}

enum CodexPluginListRunnerError: Error, Sendable { case timedOut, outputTooLarge, failed(String)
    var diagnostic: CodexPluginMCPDiscovery.Diagnostic { switch self { case .timedOut: .timedOut; case .outputTooLarge: .outputTooLarge; case let .failed(message): .commandFailed(message) } }
}

/// Process runner for the fixed `codex plugin list --json` invocation. Arguments are passed directly to Process.
nonisolated struct CodexPluginListProcessRunner: CodexPluginListRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                let stdout = Pipe(); let stderr = Pipe(); process.standardOutput = stdout; process.standardError = stderr
                let state = CodexPluginListProcessState()
                @Sendable func finish(_ result: Swift.Result<String, Error>) {
                    guard state.finishOnce() else { return }
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(with: result)
                }
                @Sendable func read(_ handle: FileHandle, stderr: Bool) {
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    if state.append(chunk, toStderr: stderr, maximum: maximumOutputBytes) { process.terminate(); finish(.failure(CodexPluginListRunnerError.outputTooLarge)) }
                }
                stdout.fileHandleForReading.readabilityHandler = { read($0, stderr: false) }
                stderr.fileHandleForReading.readabilityHandler = { read($0, stderr: true) }
                process.terminationHandler = { process in
                    let stdoutTooLarge = state.append(stdout.fileHandleForReading.availableData, toStderr: false, maximum: maximumOutputBytes)
                    let stderrTooLarge = state.append(stderr.fileHandleForReading.availableData, toStderr: true, maximum: maximumOutputBytes)
                    if stdoutTooLarge || stderrTooLarge { finish(.failure(CodexPluginListRunnerError.outputTooLarge)) }
                    else if process.terminationStatus == 0 { finish(.success(String(data: state.stdout(), encoding: .utf8) ?? "")) }
                    else { finish(.failure(CodexPluginListRunnerError.failed(String(data: state.stderr(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))) }
                }
                do { try process.run() } catch { finish(.failure(CodexPluginListRunnerError.failed(error.localizedDescription))); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate(); finish(.failure(CodexPluginListRunnerError.timedOut)) }
                }
            }
        }
    }
}

private nonisolated final class FileSystem: @unchecked Sendable {
    let fileManager: FileManager
    init(_ fileManager: FileManager) { self.fileManager = fileManager }
}

private nonisolated final class CodexPluginListProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var totalBytes = 0
    private var finished = false
    func append(_ chunk: Data, toStderr: Bool, maximum: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if toStderr { stderrData.append(chunk) } else { stdoutData.append(chunk) }; totalBytes += chunk.count; return totalBytes > maximum }
    func stdout() -> Data { lock.lock(); defer { lock.unlock() }; return stdoutData }
    func stderr() -> Data { lock.lock(); defer { lock.unlock() }; return stderrData }
    func finishOnce() -> Bool { lock.lock(); defer { lock.unlock() }; guard !finished else { return false }; finished = true; return true }
}
