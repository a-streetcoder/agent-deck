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

        // Walk up from the real pi binary location to find models.js, covering nvm,
        // volta, fnm, local installs, and anything else where the binary is a symlink
        // into a node_modules tree. Falls back to known Homebrew paths.
        let script = #"""
import { existsSync, realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const candidates = [];

const piPath = process.env.AGENT_DECK_PI_PATH;
if (piPath && existsSync(piPath)) {
  try {
    const realPath = realpathSync(piPath);
    let dir = dirname(realPath);
    for (let i = 0; i < 10; i++) {
      const earendil = resolve(dir, 'node_modules/@earendil-works/pi-ai/dist/models.js');
      const mario    = resolve(dir, 'node_modules/@mariozechner/pi-ai/dist/models.js');
      if (existsSync(earendil)) { candidates.push(earendil); break; }
      if (existsSync(mario))    { candidates.push(mario);    break; }
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  } catch {}
}

candidates.push(
  '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js',
  '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/models.js',
  '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js',
  '/usr/local/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/models.js',
);

const modulePath = candidates.find((path) => existsSync(path));
if (!modulePath) throw new Error('Could not locate pi-ai models.js');

const models = await import(modulePath);
const input = JSON.parse(process.env.AGENT_DECK_MODEL_INPUT ?? '[]');
const result = {};
for (const item of input) {
  const model = models.getModel(item.provider, item.model);
  if (!model || !model.reasoning) {
    result[`${item.provider}/${item.model}`] = ['off'];
    continue;
  }
  if (typeof models.getSupportedThinkingLevels === 'function') {
    result[`${item.provider}/${item.model}`] = models.getSupportedThinkingLevels(model);
  }
}
process.stdout.write(JSON.stringify(result));
"""#

        do {
            let result = try await commandRunner.run(
                "node",
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
                return AvailableModel(
                    provider: parts[0],
                    model: parts[1],
                    contextWindow: parts[2],
                    maxOutput: parts[3],
                    supportsThinking: supportsThinking,
                    supportsImages: parts[5].lowercased() == "yes",
                    supportedThinkingLevels: exactThinkingLevels[identifier] ?? (supportsThinking ? [] : ["off"])
                )
            }
    }
}
