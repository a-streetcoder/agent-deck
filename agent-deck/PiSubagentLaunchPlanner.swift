import Foundation

struct PiSubagentLaunchModelSelection: Equatable {
    var provider: String?
    var modelArgument: String?

    var displayName: String? {
        guard let modelArgument, !modelArgument.isEmpty else { return nil }
        guard let provider, !provider.isEmpty, !modelArgument.contains("/") else { return modelArgument }
        return "\(provider)/\(modelArgument)"
    }
}

enum PiSubagentLaunchPlanner {
    static func modelSelection(for agent: EffectiveAgentRecord, parentSession: PiAgentSessionRecord) -> PiSubagentLaunchModelSelection {
        if let explicitModel = suffixedModel(agent.resolved.model, thinking: agent.resolved.thinking) {
            return PiSubagentLaunchModelSelection(provider: nil, modelArgument: explicitModel)
        }

        let inheritedProvider = firstNonEmpty(parentSession.modelOverrideProvider, parentSession.modelProvider)
        let inheritedModel = firstNonEmpty(parentSession.modelOverrideID, parentSession.model)
        guard let inheritedModel else {
            return PiSubagentLaunchModelSelection(provider: nil, modelArgument: nil)
        }

        if inheritedProvider == nil, let split = splitProviderModel(inheritedModel) {
            return PiSubagentLaunchModelSelection(
                provider: split.provider,
                modelArgument: suffixedModel(split.model, thinking: parentSession.thinkingLevel) ?? split.model
            )
        }

        return PiSubagentLaunchModelSelection(
            provider: inheritedProvider,
            modelArgument: suffixedModel(inheritedModel, thinking: parentSession.thinkingLevel) ?? inheritedModel
        )
    }

    private static func suffixedModel(_ rawModel: String?, thinking: String?) -> String? {
        guard let model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        guard let thinking = thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty, thinking != "off" else { return model }
        let suffixes = ["off", "minimal", "low", "medium", "high", "xhigh"]
        if let suffix = model.split(separator: ":").last, suffixes.contains(String(suffix)) { return model }
        return "\(model):\(thinking)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func splitProviderModel(_ value: String) -> (provider: String, model: String)? {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
