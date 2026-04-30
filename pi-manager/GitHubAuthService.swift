import Foundation

protocol GitHubAuthService {
    func loadStatus() async -> GitHubConnectionState
    func connectUsingCLI() async throws -> GitHubSession
    func disconnect()
}
