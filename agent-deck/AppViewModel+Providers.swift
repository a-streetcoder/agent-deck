import Foundation

// MARK: - Provider enablement & sign-in

extension AppViewModel {
    func isProviderEnabled(_ provider: String) -> Bool {
        !appSettings.disabledProviders.contains(provider)
    }

    func isModelEnabled(_ model: AvailableModel) -> Bool {
        !appSettings.disabledModelIdentifiers.contains(model.identifier)
    }

    func isModelAvailable(_ model: AvailableModel) -> Bool {
        isProviderEnabled(model.provider) && isModelEnabled(model)
    }

    func setProviderEnabled(_ provider: String, isEnabled: Bool) {
        guard appSettingsController.setProviderEnabled(provider, isEnabled: isEnabled) else { return }
        appSettings = appSettingsController.settings
    }


    /// Loads the full connectable-provider list once until an explicit refresh.
    func ensureConnectableProvidersLoaded() {
        guard connectableProviderLoadState.beginInitialLoadIfNeeded() else { return }
        loadConnectableProviders()
    }

    /// Refreshes runtime metadata when Add Provider opens. A request received
    /// while a load is in flight is performed immediately afterward, never in
    /// parallel with it.
    func reloadConnectableProviders() {
        guard connectableProviderLoadState.beginRefresh() else { return }
        loadConnectableProviders()
    }

    func loadConnectableProviders() {
        isLoadingConnectableProviders = connectableProviderLoadState.isLoading
        connectableProvidersError = nil
        Task.detached(priority: .utility) {
            let providers = await PiProviderCatalogService().loadConnectableProviders()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.connectableProviders = providers
                let shouldReload = self.connectableProviderLoadState.completeLoad()
                self.isLoadingConnectableProviders = self.connectableProviderLoadState.isLoading
                if providers.isEmpty {
                    self.connectableProvidersError = LanguageStore.shared.t("vm.providersLoadFailed")
                }
                if shouldReload {
                    self.loadConnectableProviders()
                }
            }
        }
    }

    /// Reloads sign-in state from auth.json off the main thread.
    func refreshProviderAuthState() {
        Task.detached(priority: .utility) {
            let types = PiAuthCredentialStore().signedInTypes()
            await MainActor.run { [weak self] in
                self?.applyProviderAuthState(types)
            }
        }
    }

    func applyProviderAuthState(_ types: [String: String]) {
        providerAuthTypes = types
        signedInProviders = Set(types.keys)
    }

    func signOutProvider(_ provider: String) {
        providerLogoutService.onCompleted = { [weak self] in self?.reloadAfterProviderAuthChange() }
        providerLogoutService.startLogout(providerID: provider)
    }

    /// Re-reads sign-in state and re-queries the model catalog so newly
    /// authorized (or removed) providers appear/disappear. Called after Pi
    /// completes a login or logout.
    func reloadAfterProviderAuthChange() {
        refreshProviderAuthState()
        refreshAvailableModels()
    }

    func setModelEnabled(_ model: AvailableModel, isEnabled: Bool) {
        guard appSettingsController.setModelEnabled(identifier: model.identifier, isEnabled: isEnabled) else { return }
        appSettings = appSettingsController.settings
    }

    var isOpenAIFastEnabled: Bool {
        appSettings.openAIFastEnabled
    }

    func setOpenAIFastEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setOpenAIFastEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func enableAllModels() {
        guard appSettingsController.enableAllModels() else { return }
        appSettings = appSettingsController.settings
    }

}
