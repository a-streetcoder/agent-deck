import Foundation

/// A line-delimited duplex channel to an MCP server. v1 ships `MCPStdioTransport`
/// (subprocess over stdio); HTTP/SSE conform later without touching `MCPConnection`.
nonisolated protocol MCPTransport: Sendable {
    /// Whether the transport can receive an unsolicited server request and send its
    /// response independently. Streamable HTTP is request/response only today.
    var supportsDuplexServerRequests: Bool { get }
    /// Begin streaming. `onLine` receives each inbound JSON line; `onClose` fires once
    /// when the channel ends (nil = clean, non-nil = failure).
    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (MCPError?) -> Void) async throws
    /// Send one JSON-RPC message. Newline framing is the transport's responsibility.
    func send(_ line: String) async throws
    func close() async
}

extension MCPTransport {
    var supportsDuplexServerRequests: Bool { false }
}

/// stdio transport: launches the server via `/usr/bin/env <command> <args>` (so `PATH`
/// resolution works for `npx`-style commands) and streams newline-delimited JSON over
/// its stdio, reusing `PiAgentProcess`'s pipe plumbing.
actor MCPStdioTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { true }
    private let config: MCPServerConfig
    private let homeDirectory: URL
    private var process: PiAgentProcess?

    init(config: MCPServerConfig, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.config = config
        self.homeDirectory = homeDirectory
    }

    func start(onLine: @escaping @Sendable (String) -> Void,
               onClose: @escaping @Sendable (MCPError?) -> Void) async throws {
        guard config.resolvedTransport == .stdio else {
            throw MCPError.unsupportedTransport(config.resolvedTransport)
        }
        guard let rawCommand = config.command, !rawCommand.isEmpty else {
            throw MCPError.transportFailed("server has no stdio command")
        }
        let baseEnv = ProcessInfo.processInfo.environment
        let command = MCPConfigLoader.interpolate(rawCommand, environment: baseEnv, homeDirectory: homeDirectory)
        let args = (config.args ?? []).map { MCPConfigLoader.interpolate($0, environment: baseEnv, homeDirectory: homeDirectory) }
        let extraEnv = (config.env ?? [:]).mapValues { MCPConfigLoader.interpolate($0, environment: baseEnv, homeDirectory: homeDirectory) }
        let cwd: URL = {
            if let raw = config.cwd, !raw.isEmpty {
                return URL(fileURLWithPath: MCPConfigLoader.interpolate(raw, environment: baseEnv, homeDirectory: homeDirectory))
            }
            return homeDirectory
        }()

        let configuration = PiAgentProcess.Configuration(
            arguments: [command] + args,
            currentDirectoryURL: cwd,
            environment: extraEnv,
            executableURL: URL(fileURLWithPath: "/usr/bin/env")
        )
        do {
            let process = try PiAgentProcess(
                configuration: configuration,
                onStdoutLines: { lines in for line in lines { onLine(line) } },
                onStderrLines: { _ in },
                onTermination: { code in onClose(code == 0 ? nil : .transportFailed("server exited with code \(code)")) }
            )
            self.process = process
        } catch {
            throw MCPError.transportFailed(error.localizedDescription)
        }
    }

    func send(_ line: String) async throws {
        guard let process else { throw MCPError.transportFailed("transport not started") }
        // PiAgentProcess.writeJSONLine appends its own newline; strip ours to avoid a blank line.
        process.writeJSONLine(line.hasSuffix("\n") ? String(line.dropLast()) : line)
    }

    func close() async {
        process?.terminate()
        process = nil
    }
}
