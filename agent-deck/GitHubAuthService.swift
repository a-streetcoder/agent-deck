import Foundation

protocol GitHubAuthService {
    func loadStatus() async -> GitHubConnectionState
    /// Promote CLI-authenticated account to "connected" for Doctor / status UI.
    func connectUsingCLI() async throws -> GitHubSession
}
