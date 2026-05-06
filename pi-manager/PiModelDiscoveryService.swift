import Foundation

struct PiModelDiscoveryService: Sendable {
    private let commandRunner: CommandRunning

    init(commandRunner: CommandRunning = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    func loadAvailableModels() async -> [AvailableModel] {
        do {
            let result = try await commandRunner.run(
                "pi",
                arguments: ["--list-models"],
                currentDirectoryURL: nil,
                timeout: 12,
                environment: nil
            )
            guard result.exitCode == 0 else { return [] }
            let exactThinkingLevels = await loadModelThinkingLevels(fromPiListOutput: result.stdout)
            return Self.parseAvailableModels(from: result.stdout, exactThinkingLevels: exactThinkingLevels)
        } catch {
            return []
        }
    }

    private func loadModelThinkingLevels(fromPiListOutput text: String) async -> [String: [String]] {
        let knownModels = Self.availableModelIdentifiers(fromPiListOutput: text).map { ["provider": $0.provider, "model": $0.model] }
        guard !knownModels.isEmpty,
              let inputData = try? JSONSerialization.data(withJSONObject: knownModels),
              let inputText = String(data: inputData, encoding: .utf8)
        else {
            return [:]
        }

        let script = #"""
import { getModel, supportsXhigh } from '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/models.js';
const input = JSON.parse(process.env.PI_MANAGER_MODEL_INPUT ?? '[]');
const result = {};
for (const item of input) {
  const model = getModel(item.provider, item.model);
  if (!model || !model.reasoning) {
    result[`${item.provider}/${item.model}`] = ['off'];
    continue;
  }
  result[`${item.provider}/${item.model}`] = supportsXhigh(model)
    ? ['off', 'minimal', 'low', 'medium', 'high', 'xhigh']
    : ['off', 'minimal', 'low', 'medium', 'high'];
}
process.stdout.write(JSON.stringify(result));
"""#

        do {
            let result = try await commandRunner.run(
                "node",
                arguments: ["--input-type=module", "--eval", script],
                currentDirectoryURL: nil,
                timeout: 8,
                environment: ["PI_MANAGER_MODEL_INPUT": inputText]
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
                    supportedThinkingLevels: exactThinkingLevels[identifier] ?? (supportsThinking ? ["off", "minimal", "low", "medium", "high"] : ["off"])
                )
            }
    }
}
