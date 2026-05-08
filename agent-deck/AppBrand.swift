import Foundation

enum AppBrand {
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
}
