import Foundation

enum AppBrand {
    nonisolated static let betaBadgeText = "Beta"

    nonisolated static var displayName: String {
        let bundle = Bundle.main
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return "Agent Deck"
    }

    nonisolated static var marketingVersionWithStatus: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedVersion, !trimmedVersion.isEmpty else { return betaBadgeText }
        return "\(trimmedVersion) \(betaBadgeText)"
    }
}
