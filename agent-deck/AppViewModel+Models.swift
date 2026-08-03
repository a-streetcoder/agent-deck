import Foundation

// MARK: - Model catalog cache & refresh

extension AppViewModel {
    func rebuildModelCaches() {
        let foundation = FoundationModelAutomationService.availableModel()
        let disabledProviders = appSettings.disabledProviders
        let disabledIdentifiers = appSettings.disabledModelIdentifiers

        var allByIdentifier: [String: AvailableModel] = [:]
        for model in availableModels where allByIdentifier[model.identifier] == nil {
            allByIdentifier[model.identifier] = model
        }
        if let foundation, allByIdentifier[foundation.identifier] == nil {
            allByIdentifier[foundation.identifier] = foundation
        }

        let enabled = availableModels.filter { model in
            !disabledProviders.contains(model.provider) && !disabledIdentifiers.contains(model.identifier)
        }
        var enabledByIdentifier: [String: AvailableModel] = [:]
        var enabledByModel: [String: AvailableModel] = [:]
        for model in enabled {
            if enabledByIdentifier[model.identifier] == nil { enabledByIdentifier[model.identifier] = model }
            if enabledByModel[model.model] == nil { enabledByModel[model.model] = model }
        }

        var displayModels = availableModels
        if let foundation,
           !displayModels.contains(where: { $0.identifier == foundation.identifier }) {
            displayModels.insert(foundation, at: 0)
        }

        var automationModels = enabled
        if let foundation,
           !automationModels.contains(where: { $0.identifier == foundation.identifier }) {
            automationModels.insert(foundation, at: 0)
        }

        cachedFoundationAutomationModel = foundation
        cachedEnabledAvailableModels = enabled
        cachedAvailableModelByIdentifier = allByIdentifier
        cachedEnabledAvailableModelByIdentifier = enabledByIdentifier
        cachedEnabledAvailableModelByModel = enabledByModel
        cachedDisplayModels = displayModels
        cachedGroupedDisplayModels = Dictionary(grouping: displayModels, by: \.provider)
            .map { provider, models in
                (provider, models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { lhs, rhs in
                if lhs.provider == FoundationModelAutomationService.provider { return true }
                if rhs.provider == FoundationModelAutomationService.provider { return false }
                return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
            }
        cachedAutomationAvailableModels = automationModels
        cachedAutomationAvailableModelByIdentifier = Dictionary(uniqueKeysWithValues: automationModels.map { ($0.identifier, $0) })
        modelCacheRevision &+= 1
        cachedDefaultPiAgentModelLookup = nil
    }

    func rebuildExternalSkillPathCache() {
        cachedStandardizedExternalSkillPaths = Set(
            appSettings.externalSkillPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
    }

    func refreshModels() {
        refreshAvailableModels()
    }

    func ensureAvailableModelsLoaded() {
        ensurePiAgentModelCatalogLoaded()
    }

    func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) { [weak self] in
            // Keep NeuralWatt's ~/.pi/agent/models.json block in sync with the user's sign-in
            // state and NeuralWatt's live /v1/models, before querying pi. The neuralwatt block
            // exists ONLY when a real key is in ~/.pi/agent/auth.json — sign-out removes it, so
            // pi never lists NeuralWatt models without a credential. Best-effort: a failed fetch
            // leaves the existing block untouched and never blocks the model list. See
            // NeuralWattCatalogSync.
            let hasNeuralWattKey = PiAuthCredentialStore().signedInProviders().contains(NeuralWattProviderSpec.providerID)
            await NeuralWattCatalogSync().reconcile(hasRealKey: hasNeuralWattKey)
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await self?.applyAvailableModelsRefresh(models, markRefreshComplete: true)
        }
    }

    func ensurePiAgentModelCatalogLoaded() {
        guard availableModels.isEmpty else { return }
        refreshAvailableModels()
    }

    func applyAvailableModelsRefresh(_ models: [AvailableModel], markRefreshComplete: Bool) {
        availableModels = models
        modelsLastUpdatedAt = Date()
        if markRefreshComplete {
            isRefreshingModels = false
        }
    }

}
