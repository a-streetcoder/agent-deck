import Foundation

/// Historical seam for Codex Computer Use MCP injection.
/// Pi Deck no longer auto-discovers or injects `codex-computer-use`;
/// only user-configured `mcp.json` servers participate in the catalog.
nonisolated enum CodexComputerUseMCPIntegration {
    static let serverName = "codex-computer-use"

    /// Returns configured servers only (sorted). Discovery/broker arguments are ignored.
    static func merge(
        configured: [MCPServerEntry],
        discovery: CodexPluginMCPDiscovery.Result = .init(resources: [], diagnostics: []),
        brokerDiscovery: CodexComputerUseBrokerDiscovery.Result? = nil
    ) -> [MCPServerEntry] {
        _ = discovery
        _ = brokerDiscovery
        return configured.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
