import AppKit
import SwiftUI

/// Friendly labels for the handful of providers where the bare id reads poorly.
/// Everything else falls back to the id (matching the catalog).
enum ProviderDisplay {
    static func name(for provider: String) -> String {
        switch provider {
        case "anthropic": return "Anthropic (Claude)"
        case "openai-codex": return "ChatGPT / Codex"
        case "openai": return "OpenAI"
        case "github-copilot": return "GitHub Copilot"
        case "google": return "Google Gemini"
        case "google-vertex": return "Google Vertex AI"
        case "neuralwatt": return "NeuralWatt"
        case "openrouter": return "OpenRouter"
        case "xai": return "xAI"
        case "deepseek": return "DeepSeek"
        case "mistral": return "Mistral"
        case "amazon-bedrock": return "Amazon Bedrock"
        case "azure-openai-responses": return "Azure OpenAI Responses"
        case "cloudflare-ai-gateway": return "Cloudflare AI Gateway"
        case "cloudflare-workers-ai": return "Cloudflare Workers AI"
        case "kimi-coding": return "Kimi For Coding"
        case "minimax": return "MiniMax"
        case "moonshotai": return "Moonshot AI"
        case "opencode": return "OpenCode Zen"
        case "opencode-go": return "OpenCode Go"
        case "vercel-ai-gateway": return "Vercel AI Gateway"
        case "zai": return "ZAI Coding Plan (Global)"
        case "zai-coding-cn": return "ZAI Coding Plan (China)"
        case "xiaomi": return "Xiaomi MiMo"
        case "xiaomi-token-plan-cn": return "Xiaomi MiMo Token Plan (China)"
        case "xiaomi-token-plan-ams": return "Xiaomi MiMo Token Plan (Amsterdam)"
        case "xiaomi-token-plan-sgp": return "Xiaomi MiMo Token Plan (Singapore)"
        default: return provider
        }
    }
}

/// One provider row in the Add Provider picker. Matches the app's list idiom:
/// transparent by default, neutral hover wash, dimmed when already connected.
private struct ProviderPickerRow: View {
    let provider: String
    let isConnected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Connected providers stay clickable so the user can re-auth or switch
        // to a different account; the new login overwrites the stored credential.
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ProviderLogoImage(provider: provider, size: 16)
                    .frame(width: 16)
                Text(ProviderDisplay.name(for: provider))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(.horizontal, AppListMetrics.rowHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppListMetrics.cornerRadius, style: .continuous)
                    .fill(isHovering ? AppListMetrics.hoverFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppListMetrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        // Dimmed so it still reads as already-connected, but it remains active.
        .opacity(isConnected ? 0.6 : 1)
        .onHover { isHovering = $0 }
    }
}

/// Add Provider flow opened from the Models toolbar `+`. Self-contained so there
/// is no sheet-swapping: it walks picker → (auth method) → API key / OAuth in
/// place. OAuth reuses PI's own login via `PiProviderLoginService`.
struct AddProviderFlowSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: AppViewModel
    let loginService: PiProviderLoginService
    /// When set, the flow is embedded in another view (e.g. onboarding) and
    /// closing routes back via this callback instead of dismissing a sheet; the
    /// frame also flexes to fill its container rather than the fixed sheet width.
    var onClose: (() -> Void)? = nil

    private var isEmbedded: Bool { onClose != nil }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    enum Step: Equatable {
        case picker
        case method(provider: String)
        case apiKey(provider: String)
        case oauth(provider: String)
    }

    @State private var step: Step = .picker
    @State private var search = ""
    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var oauthStarted = false

    /// Used when `getProviders()` couldn't be read (e.g. node missing) so the
    /// picker is never empty.
    private static let fallbackProviders = PiProviderCatalogService.knownProviderFallbacks

    private var allProviders: [String] {
        viewModel.connectableProviders.isEmpty ? Self.fallbackProviders : viewModel.connectableProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            stepBody
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .frame(maxWidth: isEmbedded ? .infinity : nil, maxHeight: isEmbedded ? .infinity : nil)
        .frame(width: isEmbedded ? nil : 520)
        .onChange(of: oauthSucceeded) { _, success in
            guard success else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if step != .picker {
                Button {
                    goBackToPicker()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                    .fontWidth(.expanded)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var headerTitle: String {
        switch step {
        case .picker: return "Connect a provider"
        case let .method(provider), let .apiKey(provider), let .oauth(provider):
            return ProviderDisplay.name(for: provider)
        }
    }

    private var headerSubtitle: String? {
        switch step {
        case .picker: return "Sign in to a model provider without leaving Agent Deck."
        case .method: return "Select authentication method"
        case .apiKey: return "Stored locally in ~/.pi/agent/auth.json"
        case .oauth: return "Your browser opens to finish signing in"
        }
    }

    // MARK: Step bodies

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .picker: pickerBody
        case let .method(provider): methodBody(provider)
        case let .apiKey(provider): apiKeyBody(provider)
        case let .oauth(provider): oauthBody(provider)
        }
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppTextField(text: $search, placeholder: "Search providers")
                .padding(.horizontal, 18)
                .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    providerGroup("Subscriptions", providers: filtered(subscriptionProviders))
                    providerGroup("API key", providers: filtered(apiKeyProviders))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            // Cap the list so the picker is a stable height while the other
            // steps (method / API key / OAuth) size to their content — the
            // sheet then resizes per step instead of padding everything to a
            // fixed 520.
            .frame(height: 380)
        }
    }

    @ViewBuilder
    private func providerGroup(_ title: String, providers: [String]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, AppListMetrics.rowHorizontalPadding)
                VStack(spacing: AppListMetrics.rowSpacing) {
                    ForEach(providers, id: \.self) { provider in
                        ProviderPickerRow(
                            provider: provider,
                            isConnected: viewModel.signedInProviders.contains(provider),
                            onSelect: { select(provider) }
                        )
                    }
                }
            }
        }
    }

    private func methodBody(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            methodOption(
                title: "Use a subscription",
                detail: "Sign in with your \(ProviderDisplay.name(for: provider)) account in the browser.",
                systemImage: "person.crop.circle"
            ) { step = .oauth(provider: provider) }

            methodOption(
                title: "Use an API key",
                detail: "Paste an API key for this provider.",
                systemImage: "key"
            ) { step = .apiKey(provider: provider) }
        }
        .padding(18)
    }

    private func methodOption(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )
            // Stroke-only background leaves the interior transparent, so make the
            // whole card the hit target rather than just the text/icon.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func apiKeyBody(_ provider: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API key")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            SecureField("", text: $apiKey, prompt: Text("Paste your \(ProviderDisplay.name(for: provider)) API key"))
                .textFieldStyle(.plain)
                .appBrandTint()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.textContentFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppTheme.contentStroke, lineWidth: 1)
                )
                .onSubmit { saveAPIKey(provider) }
                .onChange(of: apiKey) { _, _ in errorMessage = nil }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func oauthBody(_ provider: String) -> some View {
        ProviderLoginPhaseView(service: loginService)
            .padding(18)
            .onAppear {
                guard !oauthStarted else { return }
                oauthStarted = true
                loginService.onCompleted = { [viewModel] in viewModel.reloadAfterProviderAuthChange() }
                loginService.start(providerID: provider)
            }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            switch step {
            case .picker:
                Button("Cancel") { close() }
                    .appSecondaryButton()
            case .method:
                Button("Cancel") { close() }
                    .appSecondaryButton()
            case let .apiKey(provider):
                Button("Cancel") { close() }
                    .appSecondaryButton()
                Button("Save") { saveAPIKey(provider) }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .oauth:
                Button(oauthIsTerminal ? "Close" : "Cancel") {
                    if !oauthIsTerminal { loginService.cancel() }
                    close()
                }
                .appSecondaryButton()
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func select(_ provider: String) {
        errorMessage = nil
        apiKey = ""
        if PiProviderLoginService.isOAuthCapable(provider) {
            step = .method(provider: provider)
        } else {
            step = .apiKey(provider: provider)
        }
    }

    private func goBackToPicker() {
        if case .oauth = step, !oauthIsTerminal { loginService.cancel() }
        oauthStarted = false
        errorMessage = nil
        apiKey = ""
        step = .picker
    }

    private func saveAPIKey(_ provider: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try viewModel.signInWithAPIKey(trimmed, provider: provider)
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var subscriptionProviders: [String] {
        let oauth = PiProviderLoginService.oauthCapableProviders
        let order = ["anthropic", "openai-codex", "github-copilot"]
        return allProviders.filter { oauth.contains($0) }
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    private var apiKeyProviders: [String] {
        let oauth = PiProviderLoginService.oauthCapableProviders
        let popular = ["openai", "google", "openrouter", "groq", "xai", "deepseek", "mistral"]
        return allProviders.filter { !oauth.contains($0) }
            .sorted { lhs, rhs in
                let li = popular.firstIndex(of: lhs) ?? .max
                let ri = popular.firstIndex(of: rhs) ?? .max
                if li != ri { return li < ri }
                return ProviderDisplay.name(for: lhs).localizedCaseInsensitiveCompare(ProviderDisplay.name(for: rhs)) == .orderedAscending
            }
    }

    private func filtered(_ providers: [String]) -> [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.localizedCaseInsensitiveContains(query) ||
            ProviderDisplay.name(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private var oauthSucceeded: Bool {
        if case .oauth = step, case .success = loginService.phase { return true }
        return false
    }

    private var oauthIsTerminal: Bool {
        switch loginService.phase {
        case .success, .failure: return true
        default: return false
        }
    }
}

/// Renders a `PiProviderLoginService` phase (open browser / paste code / select
/// / device code / progress / result) and feeds responses back to the service.
/// Used inside the Add Provider OAuth step.
struct ProviderLoginPhaseView: View {
    let service: PiProviderLoginService

    @State private var pasteText = ""

    var body: some View {
        Group {
            switch service.phase {
            case .launching:
                busyRow("Starting sign-in…")

            case let .opening(_, instructions):
                VStack(alignment: .leading, spacing: 10) {
                    busyRow("Opened your browser to continue.")
                    if let instructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open browser again") { service.reopenBrowser() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }

            case let .pasteCode(promptID, message, placeholder, allowEmpty):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                    TextField(placeholder ?? "Authorization code", text: $pasteText)
                        .textFieldStyle(.plain)
                        .appBrandTint()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AppTheme.textContentFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AppTheme.contentStroke, lineWidth: 1)
                        )
                        .onSubmit { submit(promptID, allowEmpty: allowEmpty) }
                    Button("Continue") { submit(promptID, allowEmpty: allowEmpty) }
                        .appPrimaryButton()
                        .disabled(!allowEmpty && pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case let .select(promptID, message, options):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                    ForEach(options) { option in
                        Button {
                            service.submit(promptID: promptID, value: option.id)
                        } label: {
                            HStack {
                                Text(option.label)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppTheme.selectionFill)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

            case let .deviceCode(userCode, _):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enter this code on the verification page:")
                        .font(.subheadline)
                    Text(userCode)
                        .font(.title2.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Button("Open verification page") { service.openVerificationPage() }
                        .appPrimaryButton()
                    busyRow("Waiting for you to authorize…")
                }

            case let .progress(message):
                busyRow(message)

            case .success:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text("Signed in.")
                        .font(.subheadline.weight(.semibold))
                }

            case let .failure(message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't sign in", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: currentPromptID) { _, _ in pasteText = "" }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            AppSpinner()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func submit(_ promptID: Int, allowEmpty: Bool) {
        let value = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !value.isEmpty else { return }
        service.submit(promptID: promptID, value: value)
    }

    private var currentPromptID: Int {
        if case let .pasteCode(promptID, _, _, _) = service.phase { return promptID }
        return 0
    }
}
