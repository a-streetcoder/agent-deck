import Foundation

/// A provider and the authentication methods advertised by the installed Pi runtime.
struct PiConnectableProvider: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let supportsAPIKey: Bool
    let supportsOAuth: Bool
}

/// Enumerates providers directly from the installed Pi runtime so the Add
/// Provider picker automatically follows Pi as providers are added or changed.
struct PiProviderCatalogService: Sendable {
    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadConnectableProviders() async -> [PiConnectableProvider] {
        let piPath = piResolver.resolve()?.path ?? "pi"

        let script = #"""
        import { existsSync, realpathSync } from 'node:fs';
        import { dirname, resolve } from 'node:path';

        function packageIndexCandidates() {
          const candidates = [];
          const piPath = process.env.AGENT_DECK_PI_PATH;
          if (piPath && existsSync(piPath)) {
            try {
              const realPath = realpathSync(piPath);
              candidates.push(resolve(dirname(realPath), 'index.js'));
              let dir = dirname(realPath);
              for (let i = 0; i < 10; i++) {
                candidates.push(resolve(dir, 'node_modules/@earendil-works/pi-coding-agent/dist/index.js'));
                candidates.push(resolve(dir, 'node_modules/@mariozechner/pi-coding-agent/dist/index.js'));
                const parent = dirname(dir);
                if (parent === dir) break;
                dir = parent;
              }
            } catch {}
          }
          candidates.push(
            '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js',
            '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js',
            '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/index.js',
            '/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/dist/index.js',
          );
          return candidates;
        }

        const indexPath = packageIndexCandidates().find((path) => existsSync(path));
        if (!indexPath) throw new Error('Could not locate the installed Pi package');

        const pi = await import(indexPath);
        if (typeof pi.ModelRuntime !== 'function' || typeof pi.ModelRuntime.create !== 'function') {
          throw new Error('This Pi version does not expose dynamic provider metadata');
        }

        const runtime = await pi.ModelRuntime.create({ allowModelNetwork: false });
        const providers = runtime.getProviders().map((provider) => ({
          id: provider.id,
          name: provider.name || provider.id,
          supportsAPIKey: Boolean(provider.auth && provider.auth.apiKey),
          supportsOAuth: Boolean(provider.auth && provider.auth.oauth),
        })).filter((provider) => provider.id && (provider.supportsAPIKey || provider.supportsOAuth));

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
                  let providers = try? JSONDecoder().decode([PiConnectableProvider].self, from: data)
            else {
                return []
            }
            return Self.normalized(providers)
        } catch {
            return []
        }
    }

    static func normalized(_ providers: [PiConnectableProvider]) -> [PiConnectableProvider] {
        var seen = Set<String>()
        return providers.compactMap { provider in
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return PiConnectableProvider(
                id: id,
                name: name.isEmpty ? id : name,
                supportsAPIKey: provider.supportsAPIKey,
                supportsOAuth: provider.supportsOAuth
            )
        }
    }
}
