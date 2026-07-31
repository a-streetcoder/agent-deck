import Foundation

enum AppBrand {
    /// Public GitHub repository for this product (`owner/name`).
    /// Used by in-app release tagging and About credits — not the upstream Agent Deck repo.
    nonisolated static let githubRepository = "mengeric/pi-deck"

    /// Upstream Agent Deck repository this fork is based on.
    nonisolated static let upstreamGitHubRepository = "a-streetcoder/agent-deck"

    nonisolated static var githubURL: URL? {
        URL(string: "https://github.com/\(githubRepository)")
    }

    nonisolated static var upstreamGitHubURL: URL? {
        URL(string: "https://github.com/\(upstreamGitHubRepository)")
    }

    nonisolated static var titleWords: [String] {
        displayName.components(separatedBy: " ")
    }

    nonisolated static var displayName: String {
        let bundle = Bundle.main
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return "Pi Deck"
    }

    nonisolated static var marketingVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "1.0" }
        return trimmed
    }
}
