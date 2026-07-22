import AppKit
import SwiftUI

/// Presentation aliases used by provider labels outside the dynamic Add Provider
/// picker. Provider availability and authentication capabilities never come from
/// this list.
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
    let provider: PiConnectableProvider
    let isConnected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        // Connected providers stay clickable so the user can re-auth or switch
        // to a different account; the new login overwrites the stored credential.
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ProviderLogoImage(provider: provider.id, size: 16)
                    .frame(width: 16)
                Text(provider.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(AppTheme.Font.micro.weight(.bold))
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
/// place. Every method uses Pi's own login via `PiProviderLoginService`.
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
    @State private var authStarted = false

    private var allProviders: [PiConnectableProvider] {
        viewModel.connectableProviders
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
        .onChange(of: authSucceeded) { _, success in
            guard success else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() }
        }
        .task {
            viewModel.reloadConnectableProviders()
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
            return providerName(for: provider)
        }
    }

    private var headerSubtitle: String? {
        switch step {
        case .picker: return "Sign in to a model provider without leaving Agent Deck."
        case .method: return "Select authentication method"
        case .apiKey: return "Pi will guide you through provider setup"
        case .oauth: return "Your browser may open to finish signing in"
        }
    }

    // MARK: Step bodies

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .picker: pickerBody
        case let .method(provider): methodBody(provider)
        case let .apiKey(provider): authBody(provider, authType: "api_key")
        case let .oauth(provider): authBody(provider, authType: "oauth")
        }
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppTextField(text: $search, placeholder: "Search providers")
                .padding(.horizontal, 18)
                .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.isLoadingConnectableProviders {
                        ProgressView("Loading providers from Pi…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    } else if let error = viewModel.connectableProvidersError, allProviders.isEmpty {
                        ContentUnavailableView {
                            Label("Providers unavailable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { viewModel.reloadConnectableProviders() }
                                .appSecondaryButton()
                        }
                        .padding(.vertical, 24)
                    } else {
                        providerGroup("Subscriptions", providers: filtered(subscriptionProviders))
                        providerGroup("API key", providers: filtered(apiKeyProviders))
                    }
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
    private func providerGroup(_ title: String, providers: [PiConnectableProvider]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(AppTheme.Font.micro.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, AppListMetrics.rowHorizontalPadding)
                VStack(spacing: AppListMetrics.rowSpacing) {
                    ForEach(providers) { provider in
                        ProviderPickerRow(
                            provider: provider,
                            isConnected: viewModel.signedInProviders.contains(provider.id),
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
                detail: "Sign in with your \(providerName(for: provider)) account in the browser.",
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
                    .font(AppTheme.Font.micro.weight(.bold))
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

    private func authBody(_ provider: String, authType: String) -> some View {
        ProviderLoginPhaseView(service: loginService)
            .padding(18)
            .onAppear {
                guard !authStarted else { return }
                authStarted = true
                loginService.onCompleted = { [viewModel] in viewModel.reloadAfterProviderAuthChange() }
                loginService.start(providerID: provider, authType: authType)
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
            case .apiKey, .oauth:
                Button(authIsTerminal ? "Close" : "Cancel") {
                    if !authIsTerminal { loginService.cancel() }
                    close()
                }
                .appSecondaryButton()
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func select(_ provider: PiConnectableProvider) {
        if provider.supportsOAuth && provider.supportsAPIKey {
            step = .method(provider: provider.id)
        } else if provider.supportsOAuth {
            step = .oauth(provider: provider.id)
        } else {
            step = .apiKey(provider: provider.id)
        }
    }

    private func goBackToPicker() {
        switch step {
        case .apiKey, .oauth where !authIsTerminal:
            loginService.cancel()
        default:
            break
        }
        authStarted = false
        step = .picker
    }

    private var subscriptionProviders: [PiConnectableProvider] {
        sorted(allProviders.filter(\.supportsOAuth))
    }

    private var apiKeyProviders: [PiConnectableProvider] {
        // Dual-auth providers live under Subscriptions and expose the existing
        // method chooser, avoiding duplicate rows in the picker.
        sorted(allProviders.filter { $0.supportsAPIKey && !$0.supportsOAuth })
    }

    private func sorted(_ providers: [PiConnectableProvider]) -> [PiConnectableProvider] {
        providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func filtered(_ providers: [PiConnectableProvider]) -> [PiConnectableProvider] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.id.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func providerName(for providerID: String) -> String {
        allProviders.first(where: { $0.id == providerID })?.name ?? providerID
    }

    private var authSucceeded: Bool {
        switch step {
        case .apiKey, .oauth:
            if case .success = loginService.phase { return true }
        default:
            break
        }
        return false
    }

    private var authIsTerminal: Bool {
        switch loginService.phase {
        case .success, .failure: return true
        default: return false
        }
    }
}

/// Renders a `PiProviderLoginService` phase (browser / dynamic prompt / select
/// / device code / progress / result) and feeds responses back to the service.
/// Used inside the Add Provider authentication step.
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

            case let .prompt(promptID, kind, message, placeholder):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                    promptField(kind: kind, placeholder: placeholder, promptID: promptID)
                    Button("Continue") { submit(promptID, kind: kind) }
                        .appPrimaryButton()
                        .disabled(kind.requiresNonEmptyEntry && pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                    .font(AppTheme.Font.micro.weight(.bold))
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

    @ViewBuilder
    private func promptField(kind: PiProviderLoginService.PromptKind, placeholder: String?, promptID: Int) -> some View {
        if kind.requiresSecureEntry {
            SecureField(placeholder ?? "Secret", text: $pasteText)
                .textFieldStyle(.plain)
                .appBrandTint()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppTheme.textContentFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(AppTheme.contentStroke, lineWidth: 1))
                .onSubmit { submit(promptID, kind: kind) }
        } else {
            AppTextField(text: $pasteText, placeholder: placeholder ?? (kind == .manualCode ? "Authorization code" : "Enter a value"), onSubmit: { submit(promptID, kind: kind) })
        }
    }

    private func submit(_ promptID: Int, kind: PiProviderLoginService.PromptKind) {
        let value = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.requiresNonEmptyEntry || !value.isEmpty else { return }
        service.submit(promptID: promptID, value: value)
    }

    private var currentPromptID: Int {
        if case let .prompt(promptID, _, _, _) = service.phase { return promptID }
        return 0
    }
}
