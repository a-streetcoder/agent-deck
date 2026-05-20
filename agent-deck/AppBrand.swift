import Foundation

enum AppBrand {
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
        return "Agent Deck"
    }

    nonisolated static var marketingVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "1.0" }
        return trimmed
    }
}
