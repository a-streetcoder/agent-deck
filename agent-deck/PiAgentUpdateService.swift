import Foundation

enum PiInstallationSource: Hashable {
    case homebrew
    case bun
    case npm
    case pnpm
    case yarn
    case piDev
    case other

    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .bun: "Bun"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .yarn: "Yarn"
        case .piDev: "pi.dev installer"
        case .other: "Pi"
        }
    }

    nonisolated static func detect(piPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> PiInstallationSource {
        let resolvedPath = URL(fileURLWithPath: piPath).resolvingSymlinksInPath().path
        let paths = [piPath, resolvedPath].map { $0.lowercased() }
        let customPNPMHome = environment["PNPM_HOME"].map {
            NSString(string: $0).expandingTildeInPath.lowercased()
        }
        let customBunBin = environment["BUN_INSTALL_BIN"].map {
            NSString(string: $0).expandingTildeInPath.lowercased()
        }
        let customBunInstall = environment["BUN_INSTALL"].map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                .appendingPathComponent("bin").path.lowercased()
        }

        if paths.contains(where: { $0.contains("/cellar/pi-coding-agent/") }) { return .homebrew }
        if let customPNPMHome, paths.contains(where: { $0.hasPrefix(customPNPMHome + "/") }) { return .pnpm }
        if let customBunBin, paths.contains(where: { $0.hasPrefix(customBunBin + "/") }) { return .bun }
        if let customBunInstall, paths.contains(where: { $0.hasPrefix(customBunInstall + "/") }) { return .bun }
        if paths.contains(where: { $0.contains("/.bun/") || $0.contains("/bun/install/global/") || $0.contains("/library/bun/") }) { return .bun }
        if paths.contains(where: { $0.contains("/.pnpm/") || $0.contains("/pnpm/") }) { return .pnpm }
        if paths.contains(where: { $0.contains("/.yarn/") || $0.contains("/yarn/") }) { return .yarn }
        if paths.contains(where: { $0.contains("/.pi/agent/bin/") }) { return .piDev }
        if paths.contains(where: {
            $0.contains("/node_modules/")
                || $0.contains("/.npm/")
                || $0.contains("/.npm-global/")
                || $0.contains("/.nvm/")
                || $0.contains("/.volta/")
        }) { return .npm }
        return .other
    }
}

struct PiAgentRuntimeStatus: Hashable {
    enum UpdateState: Hashable {
        case upToDate
        case updateAvailable(latestVersion: String)
        case unableToCheck(String)
    }

    let isInstalled: Bool
    let currentVersion: String?
    let installationSource: PiInstallationSource?
    let latestOfficialVersion: String?
    let latestSourceVersion: String?
    let updateState: UpdateState?
    let detail: String
    /// Filesystem path of the `pi` binary the app actually runs. Shown in the
    /// Doctor so "which pi am I using" stays answerable when more than one
    /// install exists (brew formula next to an npm global, for example).
    let resolvedPath: String?

    var isOfficialReleaseAheadOfSource: Bool {
        guard let latestOfficialVersion, let latestSourceVersion else { return false }
        return PiAgentUpdateService.isNewerVersion(latestOfficialVersion, than: latestSourceVersion)
    }

    static let missing = PiAgentRuntimeStatus(
        isInstalled: false,
        currentVersion: nil,
        installationSource: nil,
        latestOfficialVersion: nil,
        latestSourceVersion: nil,
        updateState: nil,
        detail: "Pi powers every coding session and is not installed yet. It can be installed for you with one click.",
        resolvedPath: nil
    )
}

struct PiAgentUpdateService {
    private struct InstalledRuntime {
        let version: String
        let resolvedPath: String?
    }

    private struct LatestVersionResponse: Decodable {
        let version: String
        let packageName: String?
    }

    private struct HomebrewFormulaResponse: Decodable {
        struct Versions: Decodable {
            let stable: String
        }

        let versions: Versions
    }

    private struct NPMRegistryResponse: Decodable {
        let version: String
    }

    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver
    private let latestVersionURL = URL(string: "https://pi.dev/api/latest-version")!
    private let homebrewFormulaURL = URL(string: "https://formulae.brew.sh/api/formula/pi-coding-agent.json")!
    private let npmRegistryURL = URL(string: "https://registry.npmjs.org/%40earendil-works%2Fpi-coding-agent/latest")!

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadStatus() async -> PiAgentRuntimeStatus {
        guard let installed = await loadInstalledRuntime() else {
            return .missing
        }
        let currentVersion = installed.version
        let resolvedPath = installed.resolvedPath
        let installationSource = resolvedPath.map { PiInstallationSource.detect(piPath: $0) } ?? .other

        let latestOfficialVersion: String
        do {
            latestOfficialVersion = try await fetchLatestOfficialVersion(currentVersion: currentVersion)
        } catch {
            return PiAgentRuntimeStatus(
                isInstalled: true,
                currentVersion: currentVersion,
                installationSource: installationSource,
                latestOfficialVersion: nil,
                latestSourceVersion: nil,
                updateState: .unableToCheck(error.localizedDescription),
                detail: "Pi is installed, but the latest official release could not be checked.",
                resolvedPath: resolvedPath
            )
        }

        let latestSourceVersion: String
        switch installationSource {
        case .homebrew:
            do {
                latestSourceVersion = try await fetchLatestHomebrewVersion()
            } catch {
                return PiAgentRuntimeStatus(
                    isInstalled: true,
                    currentVersion: currentVersion,
                    installationSource: installationSource,
                    latestOfficialVersion: latestOfficialVersion,
                    latestSourceVersion: nil,
                    updateState: .unableToCheck(error.localizedDescription),
                    detail: "Pi is installed, but the latest Homebrew release could not be checked.",
                    resolvedPath: resolvedPath
                )
            }
        case .bun, .npm, .pnpm, .yarn:
            do {
                latestSourceVersion = try await fetchLatestNPMRegistryVersion()
            } catch {
                return PiAgentRuntimeStatus(
                    isInstalled: true,
                    currentVersion: currentVersion,
                    installationSource: installationSource,
                    latestOfficialVersion: latestOfficialVersion,
                    latestSourceVersion: nil,
                    updateState: .unableToCheck(error.localizedDescription),
                    detail: "Pi is installed, but the latest npm registry release could not be checked.",
                    resolvedPath: resolvedPath
                )
            }
        case .piDev, .other:
            latestSourceVersion = latestOfficialVersion
        }

        if Self.isNewerVersion(latestSourceVersion, than: currentVersion) {
            return PiAgentRuntimeStatus(
                isInstalled: true,
                currentVersion: currentVersion,
                installationSource: installationSource,
                latestOfficialVersion: latestOfficialVersion,
                latestSourceVersion: latestSourceVersion,
                updateState: .updateAvailable(latestVersion: latestSourceVersion),
                detail: "A newer Pi release is available through \(installationSource.displayName).",
                resolvedPath: resolvedPath
            )
        }

        let isWaitingForSource = Self.isNewerVersion(latestOfficialVersion, than: latestSourceVersion)
        return PiAgentRuntimeStatus(
            isInstalled: true,
            currentVersion: currentVersion,
            installationSource: installationSource,
            latestOfficialVersion: latestOfficialVersion,
            latestSourceVersion: latestSourceVersion,
            updateState: .upToDate,
            detail: isWaitingForSource
                ? "Pi is current for \(installationSource.displayName); a newer official release is waiting for that channel."
                : "Pi is installed and up to date.",
            resolvedPath: resolvedPath
        )
    }

    /// Cheap local-only probe used while an installer is settling. It avoids
    /// repeating the remote latest-version request on every retry.
    func loadCurrentVersion() async -> String? {
        await loadInstalledRuntime()?.version
    }

    private func loadInstalledRuntime() async -> InstalledRuntime? {
        let resolvedPath = piResolver.resolve()?.path
        let piCommand = resolvedPath ?? "pi"

        do {
            let result = try await commandRunner.run(
                piCommand,
                arguments: ["--version"],
                currentDirectoryURL: nil,
                timeout: 6,
                environment: nil
            )
            guard result.exitCode == 0 else { return nil }
            let rawVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedVersion = rawVersion.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : rawVersion
            guard !resolvedVersion.isEmpty else { return nil }
            return InstalledRuntime(version: resolvedVersion, resolvedPath: resolvedPath)
        } catch {
            return nil
        }
    }

    private func fetchLatestOfficialVersion(currentVersion: String) async throws -> String {
        var request = URLRequest(url: latestVersionURL)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentDeck pi-manager (pi-agent-version: \(currentVersion))", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(LatestVersionResponse.self, from: data)
        return decoded.version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchLatestHomebrewVersion() async throws -> String {
        var request = URLRequest(url: homebrewFormulaURL)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(HomebrewFormulaResponse.self, from: data)
        return decoded.versions.stable.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchLatestNPMRegistryVersion() async throws -> String {
        var request = URLRequest(url: npmRegistryURL)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(NPMRegistryResponse.self, from: data)
        return decoded.version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let comparison = compareSemanticVersions(candidate, current) else {
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines) != current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return comparison > 0
    }

    nonisolated static func isVersion(_ installed: String, atLeast expected: String) -> Bool {
        !isNewerVersion(expected, than: installed)
    }

    nonisolated private static func compareSemanticVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = semanticVersion(lhs), let right = semanticVersion(rhs) else { return nil }
        let leftCore = [left.major, left.minor, left.patch]
        let rightCore = [right.major, right.minor, right.patch]
        if leftCore != rightCore {
            return leftCore.lexicographicallyPrecedes(rightCore) ? -1 : 1
        }
        if left.prerelease == right.prerelease { return 0 }
        if left.prerelease == nil { return 1 }
        if right.prerelease == nil { return -1 }
        return left.prerelease!.localizedStandardCompare(right.prerelease!).rawValue
    }

    nonisolated private static func semanticVersion(_ version: String) -> (major: Int, minor: Int, patch: Int, prerelease: String?)? {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
        let withoutBuildMetadata = cleaned.split(separator: "+", maxSplits: 1).first ?? Substring(cleaned)
        let pieces = withoutBuildMetadata.split(separator: "-", maxSplits: 1)
        guard let core = pieces.first else { return nil }
        let parts = core.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        let prerelease = pieces.count > 1 ? String(pieces[1]) : nil
        return (major, minor, patch, prerelease)
    }
}

private extension String {
    nonisolated func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
