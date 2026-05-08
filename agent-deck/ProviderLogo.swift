import SwiftUI

nonisolated enum ProviderLogo {
    static func assetName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "anthropic":
            return "claude"
        case "azure-openai-responses", "openai", "openai-codex":
            return "openai"
        case "github-copilot":
            return "github"
        case "kimi-coding", "moonshotai", "moonshotai-cn":
            return "kimi"
        case "minimax", "minimax-cn":
            return "minimax"
        case "mistral":
            return "mistralai"
        case "opencode", "opencode-go":
            return "opencode"
        case "openrouter":
            return "openrouter"
        case "vercel-ai-gateway":
            return "vercel"
        case "xai":
            return "xai"
        case "zai":
            return "zai"
        default:
            return nil
        }
    }
}

struct ProviderLogoImage: View {
    let provider: String
    var size: CGFloat = 16

    var body: some View {
        if let assetName = ProviderLogo.assetName(for: provider) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

struct ProviderLabel: View {
    let provider: String
    var logoSize: CGFloat = 16
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ProviderLogoImage(provider: provider, size: logoSize)
            Text(provider)
        }
    }
}
