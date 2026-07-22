import AppKit
import Foundation

/// Validates the Xcode MCP bridge's required Xcode connection without starting any
/// process. The running-app predicate is an argument so callers can test the policy
/// deterministically.
nonisolated enum MCPXcodeBridgeLaunchPreflight {
    static func isXcodeBridge(command: String, arguments: [String]) -> Bool {
        let executable = URL(fileURLWithPath: command).lastPathComponent
        if executable == "mcpbridge" { return true }
        guard executable == "xcrun" else { return false }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            // `--find` looks like a bridge invocation but only queries xcrun; it
            // never launches the bridge child that needs this availability check.
            if ["--find", "-f"].contains(argument) { return false }
            // These xcrun options consume their following argument. Other options
            // are flags or use an equals form, so skipping just the option is safe.
            if ["--sdk", "-sdk", "--toolchain", "-toolchain"].contains(argument) {
                index += 1
            }
            index += 1
        }
        guard index < arguments.count else { return false }
        return URL(fileURLWithPath: arguments[index]).lastPathComponent == "mcpbridge"
    }

    static func validate(command: String,
                         arguments: [String],
                         environment: [String: String],
                         isXcodeRunning: @Sendable () -> Bool = isRunning) throws {
        guard isXcodeBridge(command: command, arguments: arguments) else { return }
        let hasXcodePID = !(environment["MCP_XCODE_PID"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasXcodePID || isXcodeRunning() else {
            throw MCPError.transportFailed("Xcode MCP bridge requires a running Xcode instance. Open Xcode, or set MCP_XCODE_PID in the server environment.")
        }
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
    }
}

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

/// Thread-safe stderr capture shared by process callbacks. Diagnostics stay bounded;
/// configured credentials are removed before they are surfaced.
private nonisolated final class MCPStderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ newLines: [String]) {
        lock.lock()
        lines.append(contentsOf: newLines)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// stdio transport: launches the server via `/usr/bin/env <command> <args>` (so `PATH`
/// resolution works for `npx`-style commands) and streams newline-delimited JSON over
/// its stdio, reusing `PiAgentProcess`'s pipe plumbing.
actor MCPStdioTransport: MCPTransport {
    nonisolated var supportsDuplexServerRequests: Bool { true }
    private let config: MCPServerConfig
    private let homeDirectory: URL
    private let isXcodeRunning: @Sendable () -> Bool
    private var process: PiAgentProcess?

    init(config: MCPServerConfig,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         isXcodeRunning: @escaping @Sendable () -> Bool = MCPXcodeBridgeLaunchPreflight.isRunning) {
        self.config = config
        self.homeDirectory = homeDirectory
        self.isXcodeRunning = isXcodeRunning
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
        // Arguments are an argv array, not shell input. In particular, mcp-remote
        // expands placeholders such as ${AUTH_TOKEN} from the child environment.
        let args = config.args ?? []
        let childEnvironment = config.effectiveEnvironment(inherited: baseEnv, homeDirectory: homeDirectory)
        try MCPXcodeBridgeLaunchPreflight.validate(
            command: command,
            arguments: args,
            environment: childEnvironment,
            isXcodeRunning: isXcodeRunning
        )
        let cwd: URL = {
            if let raw = config.cwd, !raw.isEmpty {
                return URL(fileURLWithPath: MCPConfigLoader.interpolate(raw, environment: baseEnv, homeDirectory: homeDirectory))
            }
            return homeDirectory
        }()

        let configuration = PiAgentProcess.Configuration(
            arguments: [command] + args,
            currentDirectoryURL: cwd,
            environment: childEnvironment,
            executableURL: URL(fileURLWithPath: "/usr/bin/env")
        )
        let stderr = MCPStderrBuffer()
        let sanitizer = MCPDiagnosticSanitizer(config: config)
        do {
            let process = try PiAgentProcess(
                configuration: configuration,
                onStdoutLines: { lines in for line in lines { onLine(line) } },
                onStderrLines: { lines in stderr.append(lines) },
                onTermination: { code in
                    guard code != 0 else { onClose(nil); return }
                    let detail = sanitizer.boundedStderr(stderr.snapshot())
                    let suffix = detail.isEmpty ? "" : ": \(detail)"
                    onClose(.transportFailed("server exited with code \(code)\(suffix)"))
                }
            )
            self.process = process
        } catch {
            throw MCPError.transportFailed(sanitizer.sanitize(error.localizedDescription))
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
