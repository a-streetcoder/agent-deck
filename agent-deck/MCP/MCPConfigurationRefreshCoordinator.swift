import Foundation

/// Thread-safe generation source shared by the main-actor refresh owner and the MCP
/// connection actor. Beginning a refresh invalidates older apply operations immediately,
/// including ones currently suspended in connection close.
nonisolated final class MCPConfigurationRefreshCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    @discardableResult
    func configureIfCurrent(_ token: UInt64, servers: [MCPServerEntry], manager: MCPConnectionManager) async -> Bool {
        guard isCurrent(token) else { return false }
        await manager.configure(servers: servers, refreshToken: token, refreshCoordinator: self)
        return isCurrent(token)
    }
}
