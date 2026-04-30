import Foundation

struct GitHubCLIAuthService: GitHubAuthService {
    private let commandRunner: CommandRunning

    init(commandRunner: CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    func loadStatus() async -> GitHubConnectionState {
        do {
            let result = try await commandRunner.run(
                "gh",
                arguments: ["auth", "status", "--json", "hosts"],
                currentDirectoryURL: nil,
                timeout: 10,
                environment: nil
            )

            guard result.exitCode == 0 else {
                return unavailableOrDisconnected(from: result)
            }

            let accounts = try decodeAccounts(from: result.stdout)
            guard let account = accounts.first(where: { $0.host.caseInsensitiveCompare("github.com") == .orderedSame && $0.isActive })
                ?? accounts.first(where: { $0.host.caseInsensitiveCompare("github.com") == .orderedSame })
                ?? accounts.first
            else {
                return .disconnected
            }

            return .available(account)
        } catch let error as CommandRunnerError {
            switch error {
            case .launchFailed:
                return .unavailable(reason: "GitHub CLI (`gh`) is not installed or not on PATH.")
            case .timedOut:
                return .failed(message: "Timed out while checking GitHub CLI authentication.")
            case .nonZeroExit:
                return .disconnected
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func connectUsingCLI() async throws -> GitHubSession {
        let status = await loadStatus()
        let account: GitHubHostAccount
        switch status {
        case let .available(value), let .connected(value):
            account = value
        default:
            throw GitHubCLIAuthError.notAuthenticated
        }

        let tokenResult = try await commandRunner.run(
            "gh",
            arguments: ["auth", "token", "--hostname", account.host],
            currentDirectoryURL: nil,
            timeout: 10,
            environment: nil
        )

        guard tokenResult.exitCode == 0 else {
            throw CommandRunnerError.nonZeroExit(command: "gh auth token --hostname \(account.host)", exitCode: tokenResult.exitCode, stderr: tokenResult.stderr)
        }

        let token = tokenResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubCLIAuthError.emptyToken
        }

        return GitHubSession(source: .ghCLI, account: account, token: token)
    }

    func disconnect() {}

    private func unavailableOrDisconnected(from result: CommandResult) -> GitHubConnectionState {
        let stderr = result.stderr.lowercased()
        if stderr.contains("not logged into any hosts") || stderr.contains("authenticate") {
            return .disconnected
        }
        return .failed(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func decodeAccounts(from text: String) throws -> [GitHubHostAccount] {
        let data = Data(text.utf8)
        let response = try JSONDecoder().decode(GitHubCLIStatusResponse.self, from: data)
        return response.hosts
            .values
            .flatMap { $0 }
            .map {
                GitHubHostAccount(
                    host: $0.host,
                    login: $0.login,
                    scopes: $0.scopes
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty },
                    gitProtocol: $0.gitProtocol,
                    tokenSource: $0.tokenSource,
                    isActive: $0.active
                )
            }
    }
}

enum GitHubCLIAuthError: LocalizedError {
    case notAuthenticated
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "GitHub CLI is not authenticated. Run `gh auth login` first, then reconnect."
        case .emptyToken:
            return "GitHub CLI returned an empty token."
        }
    }
}

private struct GitHubCLIStatusResponse: Decodable {
    let hosts: [String: [GitHubCLIHostStatus]]
}

private struct GitHubCLIHostStatus: Decodable {
    let active: Bool
    let host: String
    let login: String
    let tokenSource: String?
    let scopes: String
    let gitProtocol: String?
}
