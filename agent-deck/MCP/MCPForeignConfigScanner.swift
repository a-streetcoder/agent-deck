import Foundation

/// Read-only import scanner for MCP configs owned by other tools. These files are
/// candidates for one-time import only; Agent Deck never treats them as live MCP
/// discovery sources.
nonisolated struct MCPForeignConfigScanner {
    nonisolated struct Candidate: Identifiable, Hashable, Sendable {
        var name: String
        var config: MCPServerConfig
        var sourceName: String
        var sourcePath: String

        var id: String { "\(sourcePath)#\(name)" }
    }

    var fileManager: FileManager
    var homeDirectory: URL
    var environment: [String: String]

    init(fileManager: FileManager = .default,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    static func knownLocations(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                               projectRoot: URL? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> [(name: String, url: URL, kind: SourceKind)] {
        let codexHome = environment["CODEX_HOME"].flatMap { path -> URL? in
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)

        var locations: [(name: String, url: URL, kind: SourceKind)] = [
            ("Claude Desktop", homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), .claudeJSON),
            ("Claude Desktop", homeDirectory.appendingPathComponent(".config/Claude/claude_desktop_config.json"), .claudeJSON),
            ("Claude Code", homeDirectory.appendingPathComponent(".claude.json"), .claudeJSON),
            ("Claude Code", homeDirectory.appendingPathComponent(".claude/mcp.json"), .claudeJSON),
            ("Codex", codexHome.appendingPathComponent("config.toml"), .codexTOML)
        ]
        if let projectRoot {
            locations.append(("Claude Code project", projectRoot.appendingPathComponent(".claude.json"), .claudeJSON))
            locations.append(("Codex project", projectRoot.appendingPathComponent(".codex/config.toml"), .codexTOML))
        }
        return locations
    }

    enum SourceKind: Sendable {
        case claudeJSON
        case codexTOML
    }

    func scan(excluding existingNames: Set<String> = [], projectRoot: URL? = nil) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen = Set(existingNames.map(Self.normalizedName))
        for location in Self.knownLocations(homeDirectory: homeDirectory, projectRoot: projectRoot, environment: environment) {
            let parsed: [MCPParsedServer]
            switch location.kind {
            case .claudeJSON:
                parsed = parseClaudeJSON(at: location.url)
            case .codexTOML:
                parsed = parseCodexTOML(at: location.url)
            }
            for server in parsed {
                guard let rawName = server.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { continue }
                let normalized = Self.normalizedName(rawName)
                guard !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                candidates.append(Candidate(name: rawName, config: server.config, sourceName: location.name, sourcePath: location.url.path))
            }
        }
        return candidates.sorted {
            let sourceOrder = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
            if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func parseClaudeJSON(at url: URL) -> [MCPParsedServer] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return MCPConfigParser.parse(text).filter { $0.name != nil }
    }

    func parseCodexTOML(at url: URL) -> [MCPParsedServer] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parseCodexTOML(text)
    }

    static func parseCodexTOML(_ text: String) -> [MCPParsedServer] {
        var builders: [String: TOMLServerBuilder] = [:]
        var currentServer: String?
        var currentSubsection: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = splitDottedKey(section)
                if parts.count >= 2, parts[0] == "mcp_servers" {
                    currentServer = parts[1]
                    currentSubsection = parts.count >= 3 ? parts[2] : nil
                    _ = builders[parts[1], default: TOMLServerBuilder()]
                } else {
                    currentServer = nil
                    currentSubsection = nil
                }
                continue
            }
            guard let currentServer, let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines))
            let value = String(line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))
            switch currentSubsection {
            case "env": builders[currentServer, default: TOMLServerBuilder()].env[key] = parseString(value) ?? value
            case "headers", "http_headers": builders[currentServer, default: TOMLServerBuilder()].headers[key] = parseString(value) ?? value
            case "env_http_headers": builders[currentServer, default: TOMLServerBuilder()].assignEnvHeader(header: key, envVar: parseString(value) ?? value)
            default: builders[currentServer, default: TOMLServerBuilder()].assign(key: key, value: value)
            }
        }

        return builders.compactMap { name, builder in
            guard let config = builder.config else { return nil }
            return MCPParsedServer(name: name, config: config)
        }
        .sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct TOMLServerBuilder {
        var command: String?
        var args: [String]?
        var env: [String: String] = [:]
        var cwd: String?
        var url: String?
        var headers: [String: String] = [:]
        var transport: MCPTransportKind?

        var config: MCPServerConfig? {
            var config = MCPServerConfig()
            if let url, !url.isEmpty {
                config.url = url
                config.transport = transport ?? .http
                if !headers.isEmpty { config.headers = headers }
                return config
            }
            guard let command, !command.isEmpty else { return nil }
            config.command = command
            config.args = args?.isEmpty == false ? args : nil
            config.env = env.isEmpty ? nil : env
            config.cwd = cwd?.isEmpty == false ? cwd : nil
            config.transport = .stdio
            return config
        }

        mutating func assign(key: String, value: String) {
            switch key {
            case "command": command = MCPForeignConfigScanner.parseString(value)
            case "args": args = MCPForeignConfigScanner.parseStringArray(value)
            case "env": env.merge(MCPForeignConfigScanner.parseInlineStringTable(value)) { _, new in new }
            case "env_vars":
                for name in MCPForeignConfigScanner.parseStringArray(value) ?? [] { env[name] = "${\(name)}" }
            case "cwd": cwd = MCPForeignConfigScanner.parseString(value)
            case "url": url = MCPForeignConfigScanner.parseString(value)
            case "transport", "type": transport = MCPTransportKind.normalized(MCPForeignConfigScanner.parseString(value) ?? value)
            case "headers", "http_headers": headers.merge(MCPForeignConfigScanner.parseInlineStringTable(value)) { _, new in new }
            case "bearer_token_env_var":
                if let envVar = MCPForeignConfigScanner.parseString(value), !envVar.isEmpty {
                    headers["Authorization"] = "Bearer ${\(envVar)}"
                }
            case "env_http_headers":
                for (header, envVar) in MCPForeignConfigScanner.parseInlineStringTable(value) { assignEnvHeader(header: header, envVar: envVar) }
            default: break
            }
        }

        mutating func assignEnvHeader(header: String, envVar: String) {
            let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEnv = envVar.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHeader.isEmpty, !trimmedEnv.isEmpty else { return }
            headers[trimmedHeader] = "${\(trimmedEnv)}"
        }
    }

    private static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil }
                result.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                result.append(character)
            } else if character == "#" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func parseString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if (trimmed.first == "\"" && trimmed.last == "\"") || (trimmed.first == "'" && trimmed.last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }

    private static func parseStringArray(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return splitCommaSeparated(String(trimmed.dropFirst().dropLast())).compactMap(parseString)
    }

    private static func parseInlineStringTable(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return [:] }
        var result: [String: String] = [:]
        for pair in splitCommaSeparated(String(trimmed.dropFirst().dropLast())) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let rawKey = String(pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines))
            let key = parseString(rawKey) ?? rawKey
            guard !key.isEmpty, let value = parseString(String(pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))) else { continue }
            result[key] = value
        }
        return result
    }

    private static func splitDottedKey(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in raw {
            if let active = quote {
                if character == active { quote = nil }
                else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func splitCommaSeparated(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in raw {
            if let active = quote {
                if character == active { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts
    }
}
