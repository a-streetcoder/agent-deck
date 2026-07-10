import Foundation

struct PiModelDiscoveryService: Sendable {
    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadAvailableModels() async -> [AvailableModel] {
        let piCommand = piResolver.resolve()?.path ?? "pi"

        do {
            let result = try await commandRunner.run(
                piCommand,
                arguments: ["--list-models"],
                currentDirectoryURL: nil,
                timeout: 12,
                environment: nil
            )
            guard result.exitCode == 0 else { return [] }
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            let exactThinkingLevels = await loadModelThinkingLevels(fromPiListOutput: output, piPath: piCommand)
            return Self.parseAvailableModels(from: output, exactThinkingLevels: exactThinkingLevels)
        } catch {
            return []
        }
    }

    private func loadModelThinkingLevels(fromPiListOutput text: String, piPath: String) async -> [String: [String]] {
        let knownModels = Self.availableModelIdentifiers(fromPiListOutput: text).map { ["provider": $0.provider, "model": $0.model] }
        guard !knownModels.isEmpty,
              let inputData = try? JSONSerialization.data(withJSONObject: knownModels),
              let inputText = String(data: inputData, encoding: .utf8)
        else {
            return [:]
        }

        // Walk up from the real pi binary location to find pi-coding-agent's dist, covering nvm,
        // volta, fnm, local installs, and anything else where the binary is a symlink into a
        // node_modules tree. Falls back to known Homebrew paths. We import pi's ModelRegistry
        // (not just pi-ai's `getModel`) because `getModel` only knows built-in models — custom
        // providers declared in ~/.pi/agent/models.json (NeuralWatt, Ollama, etc.) are invisible
        // to it and would wrongly resolve to ['off']. ModelRegistry loads models.json, so its
        // getAll() returns custom models with their real `reasoning` flag.
        let script = #"""
import { existsSync, realpathSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';

const candidates = [];

const piPath = process.env.AGENT_DECK_PI_PATH;
if (piPath && existsSync(piPath)) {
  try {
    const realPath = realpathSync(piPath);
    let dir = dirname(realPath);
    for (let i = 0; i < 10; i++) {
      const paAgent = resolve(dir, 'node_modules/@earendil-works/pi-coding-agent/dist/core/model-registry.js');
      if (existsSync(paAgent)) { candidates.push(paAgent); break; }
      const paMario  = resolve(dir, 'node_modules/@mariozechner/pi-coding-agent/dist/core/model-registry.js');
      if (existsSync(paMario)) { candidates.push(paMario);  break; }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch {}
}

candidates.push(
  '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/model-registry.js',
  '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/model-registry.js',
  '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/model-registry.js',
  '/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/model-registry.js',
);

const modulePath = candidates.find((path) => existsSync(path));
if (!modulePath) throw new Error('Could not locate pi-coding-agent model-registry.js');

const registryModule = await import(modulePath);
const ModelRegistry = registryModule.ModelRegistry;
// AuthStorage lives alongside ModelRegistry; load it so the registry can resolve auth-gated
// providers, then point it at the real ~/.pi/agent/models.json.
const authModule = await import(resolve(dirname(modulePath), 'auth-storage.js'));
const AuthStorage = authModule.AuthStorage;
const auth = AuthStorage.create();
const modelsJsonPath = join(homedir(), '.pi/agent/models.json');
const registry = ModelRegistry.create(auth, modelsJsonPath);
const allModels = (typeof registry.getAll === 'function') ? registry.getAll() : [];
const byKey = new Map(allModels.map((m) => [`${m.provider}/${m.id}`, m]));

// pi-ai's getSupportedThinkingLevels consumes a model object (built-in or custom) read from
// the registry, so custom-provider reasoning flags are honored. pi-ai is a dependency of
// pi-coding-agent: <pkg-root>/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js
// where <pkg-root> is the directory above dist/core.
const coreDir = dirname(modulePath);              // .../pi-coding-agent/dist/core
const distDir = dirname(coreDir);                 // .../pi-coding-agent/dist
const pkgRoot = dirname(distDir);                 // .../pi-coding-agent
const piAiCandidates = [
  resolve(pkgRoot, 'node_modules/@earendil-works/pi-ai/dist/models.js'),
  resolve(pkgRoot, 'node_modules/@mariozechner/pi-ai/dist/models.js'),
];
// Ask Node to resolve Pi's dependency from the model-registry module as well.
// This covers Bun/pnpm layouts where dependencies are linked outside pkgRoot.
const requireFromPi = createRequire(modulePath);
for (const packageName of ['@earendil-works/pi-ai', '@mariozechner/pi-ai']) {
  try {
    piAiCandidates.unshift(resolve(dirname(requireFromPi.resolve(packageName)), 'models.js'));
  } catch {}
}
const piAiPath = piAiCandidates.find((p) => existsSync(p));
const getLevels = piAiPath ? (await import(piAiPath)).getSupportedThinkingLevels : undefined;

const input = JSON.parse(process.env.AGENT_DECK_MODEL_INPUT ?? '[]');
const result = {};
for (const item of input) {
  const key = `${item.provider}/${item.model}`;
  let model = byKey.get(key);
  if (!model && item.provider.endsWith('-vertex')) {
    const baseProvider = item.provider.slice(0, -'-vertex'.length);
    if (baseProvider) {
      model = byKey.get(`${baseProvider}/${item.model}`);
    }
  }
  if (!model || !model.reasoning) {
    result[key] = ['off'];
    continue;
  }
  if (typeof getLevels === 'function') {
    result[key] = getLevels(model);
  }
}
process.stdout.write(JSON.stringify(result));
"""#

        do {
            // Finder-launched macOS apps do not inherit the user's shell PATH.
            // Resolve Node beside npm/Bun/Pi installs instead of invoking a bare
            // `node`, which previously made every thinking picker unavailable.
            let nodeCommand = piResolver.resolveNode()?.path ?? "node"
            let result = try await commandRunner.run(
                nodeCommand,
                arguments: ["--input-type=module", "--eval", script],
                currentDirectoryURL: nil,
                timeout: 8,
                environment: ["AGENT_DECK_MODEL_INPUT": inputText, "AGENT_DECK_PI_PATH": piPath]
            )
            guard result.exitCode == 0,
                  let data = result.stdout.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: [String]]
            else {
                return [:]
            }
            return object
        } catch {
            return [:]
        }
    }

    static func availableModelIdentifiers(fromPiListOutput text: String) -> [(provider: String, model: String)] {
        text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { return nil }
            return (provider: parts[0], model: parts[1])
        }
    }

    static func parseAvailableModels(from text: String, exactThinkingLevels: [String: [String]]) -> [AvailableModel] {
        text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 6 else { return nil }
                let identifier = "\(parts[0])/\(parts[1])"
                let supportsThinking = parts[4].lowercased() == "yes"
                // `pi --list-models` always prints a number for max-out (its own 16384 default
                // when the source omits a cap), so the text can't tell "real 16.4K" from "unknown."
                // Providers Agent Deck knows report no limit (NeuralWatt today) are mapped to nil
                // here so the UI shows a dash instead of pi's fabricated default.
                let maxOutput = Self.maxOutput(forProvider: parts[0], rawColumn: parts[3])
                return AvailableModel(
                    provider: parts[0],
                    model: parts[1],
                    contextWindow: parts[2],
                    maxOutput: maxOutput,
                    supportsThinking: supportsThinking,
                    supportsImages: parts[5].lowercased() == "yes",
                    supportedThinkingLevels: exactThinkingLevels[identifier]
                        ?? (supportsThinking ? PiThinkingLevelCatalog.baseline : ["off"])
                )
            }
    }

    /// Resolve the max-output column to display. Returns nil (→ dash) for providers Agent Deck
    /// knows report no limit; passes the raw pi value through otherwise.
    static func maxOutput(forProvider provider: String, rawColumn: String) -> String? {
        if NeuralWattProviderSpec.providerID == provider { return nil }
        return rawColumn
    }
}
