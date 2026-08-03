import Foundation

/// Transport a configured MCP server speaks. `stdio` connects today; `http`/`sse`
/// (remote) land with the streamable-HTTP transport.
nonisolated enum MCPTransportKind: String, Hashable, Sendable {
    case stdio
    case http
    case sse
}

extension MCPTransportKind: Codable {
    /// Lenient decode: accepts the aliases real configs use — notably
    /// `"streamable-http"` (Amplitude et al.) → `.http`. Never throws on an unknown
    /// value (defaults to `.http`), so one odd field can't drop a whole mcp.json.
    init(from decoder: Decoder) throws {
        let raw = ((try? decoder.singleValueContainer().decode(String.self)) ?? "").lowercased()
        if raw.contains("stdio") { self = .stdio }
        else if raw.contains("sse") { self = .sse }
        else { self = .http }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Normalizes a free-form transport string from pasted CLI/JSON config.
    nonisolated static func normalized(_ raw: String?) -> MCPTransportKind? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("stdio") { return .stdio }
        if raw.contains("sse") { return .sse }
        if raw.contains("http") { return .http }
        return nil
    }
}

/// When an MCP server process is started. `lazy` (default) connects on first use;
/// `eager` connects when the connection manager builds, so its tools are known up
/// front for the catalog.
nonisolated enum MCPLifecycle: String, Codable, Hashable, Sendable {
    case lazy
    case eager
}

/// One server entry from an `mcp.json` `mcpServers` map. Mirrors the shape used by
/// `pi-mcp-adapter` / `pi-mcp-extension` so existing config files load unchanged.
nonisolated struct MCPServerConfig: Codable, Hashable, Sendable {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var cwd: String?
    var url: String?
    var headers: [String: String]?
    var transport: MCPTransportKind?
    var lifecycle: MCPLifecycle?

    /// Effective transport: explicit `transport`, else inferred from the presence of
    /// `command` (stdio) vs `url` (http).
    var resolvedTransport: MCPTransportKind {
        if let transport { return transport }
        if command?.isEmpty == false { return .stdio }
        if url?.isEmpty == false { return .http }
        return .stdio
    }

    var resolvedLifecycle: MCPLifecycle { lifecycle ?? .lazy }

    /// HTTP header names are case-insensitive. Prefer the canonical spelling when a
    /// malformed config contains duplicates, then fall back to a stable key order.
    var staticAuthorizationValue: String? {
        let candidates = (headers ?? [:]).filter {
            $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return candidates.first(where: { $0.key == "Authorization" })?.value
            ?? candidates.sorted { $0.key < $1.key }.first?.value
    }

    /// A non-empty static Authorization value takes precedence over OAuth without
    /// deleting any stored OAuth state.
    var hasStaticAuthorization: Bool { staticAuthorizationValue != nil }

    /// Stdio children inherit the app environment, with server-specific values
    /// overlaid last. Values may refer to inherited variables; arguments stay literal.
    func effectiveEnvironment(
        inherited: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        let configured = (env ?? [:]).mapValues {
            MCPConfigLoader.interpolate($0, environment: inherited, homeDirectory: homeDirectory)
        }
        return inherited.merging(configured) { _, configuredValue in configuredValue }
    }

    func sanitizedDiagnostic(_ text: String) -> String {
        MCPDiagnosticSanitizer(config: self).sanitize(text)
    }
}

/// Redacts configured credentials from transport diagnostics without changing
/// requests, process environments, persisted configuration, or successful results.
nonisolated struct MCPDiagnosticSanitizer: Sendable {
    private let secrets: [String]

    init(config: MCPServerConfig) {
        var values: [String] = []
        for (name, value) in config.headers ?? [:]
        where Self.isSecretName(name) && !value.isEmpty {
            values.append(value)
        }
        for (name, value) in config.env ?? [:]
        where Self.isSecretName(name) && !value.isEmpty {
            values.append(value)
        }
        secrets = Array(Set(values)).sorted { $0.count > $1.count }
    }

    func sanitize(_ text: String) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        return result
    }

    func boundedStderr(_ lines: [String], maximumCharacters: Int = 4_000) -> String {
        let joined = sanitize(lines.suffix(40).joined(separator: "\n"))
        guard joined.count > maximumCharacters else { return joined }
        return "…" + joined.suffix(maximumCharacters)
    }

    static func isSecretName(_ name: String) -> Bool {
        let normalized = name.uppercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "AUTHORIZATION"
            || normalized.contains("TOKEN")
            || normalized.contains("SECRET")
            || normalized.contains("PASSWORD")
            || normalized.contains("PASSWD")
            || normalized.contains("API_KEY")
            || normalized.contains("PRIVATE_KEY")
            || normalized.contains("CREDENTIAL")
    }
}

/// Global `settings` block of an `mcp.json` file. Only the fields Agent Deck reads.
nonisolated struct MCPSettings: Codable, Hashable, Sendable {
    var toolPrefix: String?
    var enabled: Bool?
}

/// Top-level shape of an `mcp.json` file.
nonisolated struct MCPServersFile: Codable, Hashable, Sendable {
    var mcpServers: [String: MCPServerConfig]?
    var settings: MCPSettings?
}

/// Provenance of a catalog server. Plugin definitions are discovered read-only and
/// are never persistence targets.
nonisolated enum MCPServerProvenance: Hashable, Sendable {
    case config
    case codexPlugin(version: String?, availability: String?)
}

/// Native tool-catalog restrictions for supported adapters.
nonisolated enum MCPServerToolPolicy: Hashable, Sendable {
    case unrestricted

    func allows(_ tool: String) -> Bool {
        switch self {
        case .unrestricted: true
        }
    }
}

/// A resolved server with provenance: the merged config plus the on-disk file it
/// came from (for the management UI and for "this is read-only" affordances).
nonisolated struct MCPServerEntry: Hashable, Sendable, Identifiable {
    var name: String
    var config: MCPServerConfig
    /// Absolute path of the `mcp.json` this entry's config was read from.
    var sourcePath: String
    var provenance: MCPServerProvenance = .config
    var toolPolicy: MCPServerToolPolicy = .unrestricted
    /// A transient plugin server can retain its stable assignment identity while its
    /// current resolved helper is unavailable. Such an entry is never configured.
    var availabilityDiagnostic: String?
    var diagnostic: String?
    var isAvailable: Bool { availabilityDiagnostic == nil }
    var id: String { name }
}

/// Loads and merges the standard `mcp.json` locations. All file I/O is synchronous,
/// so call from a background context when on a hot path.
nonisolated struct MCPConfigLoader {
    /// The four config locations, lowest-to-highest precedence. Later files override
    /// earlier ones per server name. Matches the precedence the community adapters use.
    static func configLocations(homeDirectory: URL, projectRoot: URL?) -> [URL] {
        var locations: [URL] = [
            homeDirectory.appendingPathComponent(".config/mcp/mcp.json"),
            homeDirectory.appendingPathComponent(".pi/agent/mcp.json")
        ]
        if let projectRoot {
            locations.append(projectRoot.appendingPathComponent(".mcp.json"))
            locations.append(projectRoot.appendingPathComponent(".pi/mcp.json"))
        }
        return locations
    }

    /// The single location Agent Deck writes to when the user edits servers in the UI.
    static func writableConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".pi/agent/mcp.json")
    }

    var fileManager: FileManager
    var homeDirectory: URL

    init(fileManager: FileManager = .default,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    /// Returns merged server entries (later locations win on name collision) plus the
    /// effective settings (last non-nil settings block wins).
    func load(projectRoot: URL?) -> (servers: [MCPServerEntry], settings: MCPSettings?) {
        var merged: [String: MCPServerEntry] = [:]
        var settings: MCPSettings?
        for location in Self.configLocations(homeDirectory: homeDirectory, projectRoot: projectRoot) {
            guard let file = parse(location) else { continue }
            if let fileSettings = file.settings { settings = fileSettings }
            for (name, config) in file.mcpServers ?? [:] {
                merged[name] = MCPServerEntry(name: name, config: config, sourcePath: location.path)
            }
        }
        let servers = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (servers, settings)
    }

    func parse(_ url: URL) -> MCPServersFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPServersFile.self, from: data)
    }

    // MARK: - Interpolation

    /// Expands `${VAR}` / `$VAR` references (from `environment`) and a leading `~`
    /// (to `homeDirectory`) in a raw config string. Unknown variables expand to "".
    static func interpolate(_ raw: String,
                            environment: [String: String],
                            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var result = expandVariables(raw, environment: environment)
        if result == "~" {
            result = homeDirectory.path
        } else if result.hasPrefix("~/") {
            result = homeDirectory.path + String(result.dropFirst(1))
        }
        return result
    }

    /// Replaces `${NAME}` and `$NAME` tokens. `$NAME` consumes an identifier run
    /// (letters, digits, underscore); `${NAME}` consumes up to the closing brace.
    private static func expandVariables(_ raw: String, environment: [String: String]) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "$" else {
                output.append(character)
                index = raw.index(after: index)
                continue
            }
            let afterDollar = raw.index(after: index)
            guard afterDollar < raw.endIndex else {
                output.append(character)
                index = afterDollar
                continue
            }
            if raw[afterDollar] == "{" {
                if let close = raw[afterDollar...].firstIndex(of: "}") {
                    let name = String(raw[raw.index(after: afterDollar)..<close])
                    output.append(environment[name] ?? "")
                    index = raw.index(after: close)
                    continue
                }
                output.append(character)
                index = afterDollar
                continue
            }
            if raw[afterDollar].isLetter || raw[afterDollar] == "_" {
                var cursor = afterDollar
                while cursor < raw.endIndex, raw[cursor].isLetter || raw[cursor].isNumber || raw[cursor] == "_" {
                    cursor = raw.index(after: cursor)
                }
                let name = String(raw[afterDollar..<cursor])
                output.append(environment[name] ?? "")
                index = cursor
                continue
            }
            output.append(character)
            index = afterDollar
        }
        return output
    }
}
