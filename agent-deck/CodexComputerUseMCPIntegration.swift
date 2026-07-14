import Foundation

/// Maps the verified Codex Computer Use discovery seam into Agent Deck's stable MCP
/// catalog. No discovered path is persisted: every config here is rebuilt per refresh.
nonisolated enum CodexComputerUseMCPIntegration {
    static let serverName = "codex-computer-use"

    static func merge(configured: [MCPServerEntry], discovery: CodexPluginMCPDiscovery.Result) -> [MCPServerEntry] {
        var merged = Dictionary(uniqueKeysWithValues: configured.map { ($0.name, $0) })
        let resource = discovery.resources.first { $0.serverName == "computer-use" }

        if let existing = merged[serverName] {
            if resource != nil {
                var entry = existing
                entry.diagnostic = "The configured server named \(serverName) is in use instead of the Codex Plugin server and is not governed by Agent Deck's Computer Use session-control policy."
                merged[serverName] = entry
            }
        } else if let resource {
            merged[serverName] = MCPServerEntry(
                name: serverName,
                config: resource.config,
                sourcePath: resource.sourcePath,
                provenance: .codexPlugin(version: resource.version, availability: "Available"),
                toolPolicy: .computerUseSessionControlled
            )
        } else {
            let status = discovery.diagnostics.map(\.localizedDescription).joined(separator: " ")
            merged[serverName] = MCPServerEntry(
                name: serverName,
                config: MCPServerConfig(),
                sourcePath: "",
                provenance: .codexPlugin(version: nil, availability: "Unavailable"),
                toolPolicy: .computerUseSessionControlled,
                availabilityDiagnostic: status.isEmpty ? "Codex Computer Use is unavailable." : status
            )
        }
        return merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
