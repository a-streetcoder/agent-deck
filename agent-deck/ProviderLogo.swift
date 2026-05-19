import SwiftUI

nonisolated enum ProviderLogo {
    static func systemSymbolName(for provider: String) -> String? {
        switch provider.lowercased() {
        case "apple":
            return "apple.logo"
        default:
            return nil
        }
    }

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
        if let symbolName = ProviderLogo.systemSymbolName(for: provider) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.monochrome)
                .imageScale(.large)
                .frame(width: size, height: size, alignment: .center)
                .accessibilityHidden(true)
        } else if let assetName = ProviderLogo.assetName(for: provider) {
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
        Label {
            Text(displayName)
        } icon: {
            ProviderLogoImage(provider: provider, size: logoSize)
        }
        .labelStyle(ProviderInlineLabelStyle(spacing: spacing))
    }

    private var displayName: String {
        provider.lowercased() == "apple" ? "Apple" : provider
    }
}

private struct ProviderInlineLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}
