import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoundationModelAutomationService {
    static let provider = "apple"
    static let model = "foundation"
    static let identifier = "\(provider)/\(model)"

    static func isFoundationModel(_ model: AvailableModel) -> Bool {
        model.identifier == identifier
    }

    static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    static func availableModel() -> AvailableModel? {
        guard isAvailable() else { return nil }
        return AvailableModel(
            provider: provider,
            model: model,
            contextWindow: "4K",
            maxOutput: "2K",
            supportsThinking: false,
            supportsImages: false,
            supportedThinkingLevels: ["off"]
        )
    }

    static func generateOneShot(
        prompt: String,
        systemPrompt: String,
        temperature: Double = 0.2,
        maxTokens: Int = 256
    ) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: systemPrompt)
        let options = GenerationOptions(
            sampling: nil,
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(to: prompt, options: options)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw FoundationModelAutomationError.notAvailable
        #endif
    }
}

enum FoundationModelAutomationError: LocalizedError {
    case notAvailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Apple Foundation Model is not available on this Mac."
        case .emptyResponse:
            return "Apple Foundation Model returned an empty response."
        }
    }
}
