import Foundation
import OSLog

/// Keeps the `neuralwatt` block of `~/.pi/agent/models.json` in sync with NeuralWatt's live
/// `/v1/models` endpoint.
///
/// `models.json` is pi's config file (pi's `ModelRegistry` reads it on launch and on
/// `pi --list-models`). The block is written **only when a real API key exists in
/// `~/.pi/agent/auth.json`** (Pi's `ModelRuntime` writes it after the Add
/// Provider `+` flow completes). When no key exists, any stale `neuralwatt` block is
/// removed, so pi never lists NeuralWatt models without a credential and there is no possibility
/// of "on without a key."
///
/// Pi's loader REQUIRES an `apiKey` field on a custom provider that declares models (it throws
/// `"apiKey" is required when defining custom models"` and silently drops the provider otherwise).
/// We write a literal `"placeholder"` there purely to satisfy that loader check — it is never
/// sent. Pi's `AuthStorage.getApiKey` (priority 2) returns the real `auth.json` key before ever
/// consulting the `models.json` value (priority 5), so the key the user added is what gets sent.
/// A literal placeholder is treated as "configured" by pi's `hasConfiguredAuth`, which is exactly
/// why the block must not exist at all when there's no real key. See
/// [[project-neuralwatt-native-provider]].
///
/// Reconcile is best-effort and never throws to callers. If the fetch fails or the file is
/// unreadable, existing on-disk state is preserved so a flaky network or a corrupt file never
/// blocks model refresh.
nonisolated struct NeuralWattCatalogSync: Sendable {
    private static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "NeuralWattSync")

    private let urlSession: URLSession
    private let fileURL: URL
    private let fetch: @Sendable () async throws -> Data

    /// Production initializer. `fetch` hits `NeuralWattProviderSpec.modelsEndpoint`.
    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.fileURL = Self.modelsFileURL
        self.fetch = { [urlSession] in
            var request = URLRequest(url: NeuralWattProviderSpec.modelsEndpoint)
            request.timeoutInterval = 10
            // Public endpoint; NeuralWatt documents no auth for /v1/models. Do not send a key.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    /// Test initializer: inject the fetch and the target file independently of network/disk.
    init(fileURL: URL, fetch: @escaping @Sendable () async throws -> Data) {
        self.urlSession = .shared
        self.fileURL = fileURL
        self.fetch = fetch
    }

    /// `~/.pi/agent/models.json` — matches pi's `getAgentDir()` and the app's hardcoded
    /// `~/.pi/agent` usage (see `PiAuthCredentialStore.authFileURL`).
    nonisolated static var modelsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/models.json")
    }

    /// Bring the `neuralwatt` block in line with the user's sign-in state.
    ///
    /// - When `hasRealKey` is true (a NeuralWatt `api_key` exists in `~/.pi/agent/auth.json`):
    ///   fetch `/v1/models`, build the provider block, and merge it into `models.json`, preserving
    ///   every other provider.
    /// - When `hasRealKey` is false: remove any stale `neuralwatt` block so pi does not list
    ///   NeuralWatt models without a credential. (The literal `apiKey: "placeholder"` would
    ///   otherwise satisfy pi's `hasConfiguredAuth` on its own.)
    ///
    /// Returns the discovered model ids (empty when no block was written — no key, fetch failure,
    /// or empty catalog — in which case the on-disk state is left untouched for the signaled-out
    /// case only when there's nothing to remove).
    @discardableResult
    func reconcile(hasRealKey: Bool) async -> [String] {
        guard hasRealKey else {
            do {
                try removeBlock()
            } catch {
                Self.logger.error("NeuralWatt models.json block removal failed: \(String(describing: error), privacy: .public)")
            }
            return []
        }

        let fetched: Data
        do {
            fetched = try await fetch()
        } catch {
            Self.logger.notice("NeuralWatt /v1/models fetch failed; leaving models.json untouched: \(String(describing: error), privacy: .public)")
            return []
        }

        let modelEntries: [[String: Any]]
        do {
            modelEntries = try Self.parseProviderModels(from: fetched)
        } catch {
            Self.logger.notice("NeuralWatt /v1/models payload unparseable; leaving models.json untouched: \(String(describing: error), privacy: .public)")
            return []
        }

        guard !modelEntries.isEmpty else {
            // Empty catalog: leave a previously-written block alone (likely transient outage).
            Self.logger.notice("NeuralWatt /v1/models returned no models; leaving models.json untouched")
            return []
        }

        let providerBlock = Self.buildProviderBlock(models: modelEntries)

        do {
            try writeMergingExisting(providerBlock: providerBlock)
        } catch {
            Self.logger.error("NeuralWatt models.json write failed: \(String(describing: error), privacy: .public)")
        }
        return modelEntries.compactMap { $0["id"] as? String }
    }

    // MARK: - Parsing /v1/models

    /// Parse the OpenAI-style `{ data: [ { id, metadata: { display_name, pricing, capabilities, limits } } ] }`
    /// payload into per-model `models.json` dicts (everything except the provider-level fields).
    static func parseProviderModels(from data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = object["data"] as? [[String: Any]]
        else {
            throw URLError(.cannotParseResponse)
        }

        return dataArray.compactMap { entry -> [String: Any]? in
            guard let id = entry["id"] as? String else { return nil }
            let metadata = entry["metadata"] as? [String: Any] ?? [:]
            let capabilities = metadata["capabilities"] as? [String: Any] ?? [:]
            let limits = metadata["limits"] as? [String: Any] ?? [:]
            let pricing = metadata["pricing"] as? [String: Any] ?? [:]

            var model: [String: Any] = [
                "id": id,
                "name": (metadata["display_name"] as? String) ?? id,
                "reasoning": (capabilities["reasoning"] as? Bool) ?? false,
                "input": (capabilities["vision"] as? Bool) == true ? ["text", "image"] : ["text"],
                "contextWindow": (limits["max_context_length"] as? Int) ?? 131072,
                "cost": buildCost(from: pricing),
            ]

            // maxTokens is OMITTED when the endpoint reports no output cap (null). Parsers
            // reading `pi --list-models` map the absence to a dash rather than pi's
            // 16384 default. When NeuralWatt starts reporting a real limit, it flows through
            // here automatically.
            if let maxOut = limits["max_output_tokens"] as? Int, maxOut > 0 {
                model["maxTokens"] = maxOut
            }

            if let compat = NeuralWattProviderSpec.compat(forModelID: id), !compat.isEmpty {
                model["compat"] = compat
            }
            return model
        }
    }

    private static func buildCost(from pricing: [String: Any]) -> [String: Any] {
        // pi's `cost` fields are in dollars per million tokens (see pi docs "cost ... per million
        // tokens"), and NeuralWatt's `pricing.input_per_million` is in the same unit, so pass
        // the value through directly — do NOT divide.
        func perMillion(_ key: String) -> Double {
            ((pricing[key] as? Double) ?? (pricing[key] as? Int).map(Double.init)) ?? 0
        }
        return [
            "input": perMillion("input_per_million"),
            "output": perMillion("output_per_million"),
            "cacheRead": perMillion("cached_input_per_million"),
            "cacheWrite": 0,
        ]
    }

    // MARK: - Provider block

    static func buildProviderBlock(models: [[String: Any]]) -> [String: Any] {
        let block: [String: Any] = [
            "name": NeuralWattProviderSpec.displayName,
            "baseUrl": NeuralWattProviderSpec.baseURL,
            "api": NeuralWattProviderSpec.api,
            "authHeader": NeuralWattProviderSpec.authHeader,
            "apiKey": "placeholder",
            "compat": NeuralWattProviderSpec.providerCompat,
            "models": models,
        ]
        return block
    }

    // MARK: - File merge (mirrors PiAuthCredentialStore's atomic-write idiom)

    private func writeMergingExisting(providerBlock: [String: Any]) throws {
        try mutateProviders { providers in
            providers[NeuralWattProviderSpec.providerID] = providerBlock
        }
    }

    private func removeBlock() throws {
        try mutateProviders { providers in
            providers.removeObject(forKey: NeuralWattProviderSpec.providerID)
        }
    }

    /// Load `models.json` as a raw `[String: Any]`, run `mutate` against its `providers` dict,
    /// and atomically write it back (preserving every other provider byte-for-byte). Creates the
    /// file if absent. An unreadable file is backed up before being overwritten so a corrupt
    /// `models.json` never silently eats sibling providers.
    private func mutateProviders(_ mutate: (inout NSMutableDictionary) -> Void) throws {
        let directory = fileURL.deletingLastPathComponent()
        try Self.ensureDirectory(directory)

        var providers: NSMutableDictionary = [:]
        if let existing = try? Self.loadRaw(fileURL: fileURL),
           let existingProviders = existing["providers"] as? NSMutableDictionary
        {
            providers = existingProviders
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            // File exists but is unreadable JSON. Back it up rather than clobber siblings.
            let backupURL = directory.appendingPathComponent("models.json.bak-\(UUID().uuidString)")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            Self.logger.notice("NeuralWatt sync backed up unreadable models.json to \(backupURL.lastPathComponent, privacy: .public)")
        }

        mutate(&providers)

        let root: [String: Any] = ["providers": providers]
        let payload = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tempURL = directory.appendingPathComponent("models.json.tmp-\(UUID().uuidString)")
        try payload.write(to: tempURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Read the raw root object without modeling the whole file (other providers carry unknown
    /// shapes; round-trip them untouched).
    /// Load the root as mutable containers so the caller can mutate `providers` in place.
    private static func loadRaw(fileURL: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let raw = try Data(contentsOf: fileURL)
        guard !raw.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: raw, options: .mutableContainers) as? [String: Any]
        else { return nil }
        return object
    }

    private static func ensureDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
