import Foundation

/// Reads Pi's shared credential file (`~/.pi/agent/auth.json`) for status UI.
///
/// Pi owns every credential mutation through `ModelRuntime`, including its
/// cross-process lock. Agent Deck only reads non-secret provider/type metadata.
struct PiAuthCredentialStore: Sendable {
    enum StoreError: LocalizedError {
        case corrupt(path: String)

        var errorDescription: String? {
            switch self {
            case let .corrupt(path):
                return "\(path) is not valid JSON. Fix or remove it, then try again."
            }
        }
    }

    /// `~/.pi/agent/auth.json` — matches PI's `getAgentDir()` and the rest of
    /// the app's hardcoded `~/.pi/agent` usage (see `EnvPersistence`).
    nonisolated static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json")
    }

    private let fileURL: URL

    nonisolated init(fileURL: URL = PiAuthCredentialStore.authFileURL) {
        self.fileURL = fileURL
    }

    /// Provider ids that currently have any credential. Presence == signed in.
    nonisolated func signedInProviders() -> Set<String> {
        (try? load()).map { Set($0.keys) } ?? []
    }

    /// `"api_key"`, `"oauth"`, or `nil` if the provider isn't signed in.
    nonisolated func credentialType(for provider: String) -> String? {
        ((try? load())?[provider]?["type"] as? String)
    }

    /// Provider id → credential type (`"api_key"`/`"oauth"`) in a single read.
    nonisolated func signedInTypes() -> [String: String] {
        guard let data = try? load() else { return [:] }
        return data.reduce(into: [:]) { $0[$1.key] = $1.value["type"] as? String }
    }

    // MARK: - Disk

    /// Returns `{}` when the file is absent; throws `.corrupt` rather than
    /// silently overwriting an unreadable file.
    nonisolated private func load() throws -> [String: [String: Any]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let raw = try Data(contentsOf: fileURL)
        guard !raw.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: raw),
              let dictionary = object as? [String: [String: Any]]
        else {
            throw StoreError.corrupt(path: (fileURL.path as NSString).abbreviatingWithTildeInPath)
        }
        return dictionary
    }

}
