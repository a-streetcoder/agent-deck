import Foundation

/// Enumerates every provider PI can connect to — not just the ones currently in
/// the model catalog. `pi --list-models` only surfaces providers with free or
/// already-authorized models, so the Add Provider picker reads the full list
/// from pi-ai's `getProviders()` plus any custom providers declared in
/// `~/.pi/agent/models.json`.
struct PiProviderCatalogService: Sendable {
    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver

    /// Minimum built-in provider list for the Add Provider picker. Pi's
    /// getProviders() is still the source of truth when available, but this
    /// prevents a non-empty partial result (for example only NeuralWatt from
    /// Agent Deck's bundled sync) from hiding standard providers like
    /// OpenRouter.
    static let knownProviderFallbacks = [
        "anthropic", "openai-codex", "github-copilot",
        "openai", "google", "openrouter", "groq", "xai", "deepseek",
        "mistral", "cerebras", "together", "fireworks", "nvidia", "huggingface",
        "amazon-bedrock", "azure-openai-responses", "cloudflare-ai-gateway",
        "cloudflare-workers-ai", "kimi-coding", "minimax", "moonshotai",
        "opencode", "opencode-go", "vercel-ai-gateway", "zai", "zai-coding-cn",
        "xiaomi", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp"
    ]

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadConnectableProviders() async -> [String] {
        let piPath = piResolver.resolve()?.path ?? "pi"

        // Walk up from the real pi binary to pi-ai's compat.js (same technique
        // as PiModelDiscoveryService), then call the static-catalog getProviders().
        let script = #"""
        import { existsSync, realpathSync, readFileSync } from 'node:fs';
        import { dirname, resolve, join } from 'node:path';
        import { homedir } from 'node:os';

        const candidates = [];
        const piPath = process.env.AGENT_DECK_PI_PATH;
        if (piPath && existsSync(piPath)) {
          try {
            const realPath = realpathSync(piPath);
            let dir = dirname(realPath);
            for (let i = 0; i < 10; i++) {
              const earendil = resolve(dir, 'node_modules/@earendil-works/pi-ai/dist/compat.js');
              const mario    = resolve(dir, 'node_modules/@mariozechner/pi-ai/dist/compat.js');
              if (existsSync(earendil)) { candidates.push(earendil); break; }
              if (existsSync(mario))    { candidates.push(mario);    break; }
              const parent = dirname(dir);
              if (parent === dir) break;
              dir = parent;
            }
          } catch {}
        }
        candidates.push(
          '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js',
          '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js',
        );

        const modulePath = candidates.find((p) => existsSync(p));
        if (!modulePath) throw new Error('Could not locate pi-ai compat.js');
        const models = await import(modulePath);
        const builtInProviders = typeof models.getProviders === 'function' ? models.getProviders() : [];

        // Surface custom providers from ~/.pi/agent/models.json and already-signed-in
        // providers from auth.json so the picker stays aligned with PI's runtime state.
        let customProviders = [];
        let authProviders = [];
        try {
          const modelsJsonPath = join(homedir(), '.pi/agent/models.json');
          if (existsSync(modelsJsonPath)) {
            const modelsJson = JSON.parse(readFileSync(modelsJsonPath, 'utf8'));
            customProviders = Object.keys(modelsJson.providers || {});
          }
        } catch {}
        try {
          const authJsonPath = join(homedir(), '.pi/agent/auth.json');
          if (existsSync(authJsonPath)) {
            const authJson = JSON.parse(readFileSync(authJsonPath, 'utf8'));
            authProviders = Object.keys(authJson || {});
          }
        } catch {}

        // Bundled providers Agent Deck self-manages via NeuralWattCatalogSync appear here even
        // before models.json exists, so a fresh machine can add NeuralWatt through the picker
        // and have the sync seed the file. Keep in sync with NeuralWattProviderSpec.providerID.
        const bundledProviders = ['neuralwatt'];

        const providers = Array.from(new Set([...builtInProviders, ...customProviders, ...authProviders, ...bundledProviders]));
        process.stdout.write(JSON.stringify(providers));
        """#

        do {
            let result = try await commandRunner.run(
                "node",
                arguments: ["--input-type=module", "--eval", script],
                currentDirectoryURL: nil,
                timeout: 8,
                environment: ["AGENT_DECK_PI_PATH": piPath]
            )
            guard result.exitCode == 0,
                  let data = result.stdout.data(using: .utf8),
                  let providers = try JSONSerialization.jsonObject(with: data) as? [String]
            else {
                return []
            }
            return Self.mergingKnownProviderFallbacks(into: providers)
        } catch {
            return Self.knownProviderFallbacks
        }
    }

    static func mergingKnownProviderFallbacks(into providers: [String]) -> [String] {
        var seen = Set<String>()
        return (providers + knownProviderFallbacks).compactMap { rawProvider in
            let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty, seen.insert(provider).inserted else { return nil }
            return provider
        }
    }
}
