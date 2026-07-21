import Foundation

struct PiExecutableResolver: Sendable {
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedURL: (key: String, url: URL)?

    /// Overridable candidate list so tests can force a "pi not found" state on
    /// machines that have pi installed in a standard location. Defaults to the
    /// standard install paths; see `commonPiCandidates()`.
    private nonisolated let candidatesProvider: @Sendable () -> [URL]

    /// Directories always searched after `PATH`. Defaults to the standard macOS
    /// bin locations so the OAuth login bridge still finds `pi`/`node` when
    /// launched with a minimal `PATH`. Injectable so tests can force "not found".
    private nonisolated let defaultPathDirectories: @Sendable () -> [String]
    /// Production resolution is cached process-wide. Tests with injected
    /// candidates can disable that cache so a previously resolved real Pi
    /// cannot leak into a fixture.
    private nonisolated let cacheResults: Bool

    nonisolated init(
        candidatesProvider: @Sendable @escaping () -> [URL] = { PiExecutableResolver.commonPiCandidates() },
        defaultPathDirectories: @Sendable @escaping () -> [String] = { ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] },
        cacheResults: Bool = true
    ) {
        self.candidatesProvider = candidatesProvider
        self.defaultPathDirectories = defaultPathDirectories
        self.cacheResults = cacheResults
    }

    nonisolated func resolve() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let cacheKey = Self.cacheKey(for: environment)

        PiExecutableResolver.cacheLock.lock()
        if cacheResults,
           let cached = PiExecutableResolver.cachedURL,
           cached.key == cacheKey,
           FileManager.default.isExecutableFile(atPath: cached.url.path) {
            PiExecutableResolver.cacheLock.unlock()
            return cached.url
        }
        PiExecutableResolver.cacheLock.unlock()

        guard let resolved = resolveUncached(environment: environment) else {
            return nil
        }

        if cacheResults {
            PiExecutableResolver.cacheLock.lock()
            PiExecutableResolver.cachedURL = (cacheKey, resolved)
            PiExecutableResolver.cacheLock.unlock()
        }
        return resolved
    }

    nonisolated private static func cacheKey(for environment: [String: String]) -> String {
        [
            environment["AGENT_DECK_PI_PATH"] ?? "",
            environment["PI_CLI_PATH"] ?? "",
            environment["BUN_INSTALL"] ?? "",
            environment["BUN_INSTALL_BIN"] ?? "",
            environment["PNPM_HOME"] ?? "",
            environment["SHELL"] ?? "",
            environment["PATH"] ?? ""
        ].joined(separator: "\u{1f}")
    }

    nonisolated private func resolveUncached(environment: [String: String]) -> URL? {
        for key in ["AGENT_DECK_PI_PATH", "PI_CLI_PATH"] {
            if let raw = environment[key], let url = executableURL(from: raw) {
                return url
            }
        }

        if let pathResolved = resolveExecutableInPATH("pi", environment: environment) {
            return pathResolved
        }

        let candidates = candidatesProvider()
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        return nil
    }

    nonisolated private func executableURL(from raw: String) -> URL? {
        let expanded = NSString(string: raw).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        return nil
    }

    nonisolated private func resolveExecutableInPATH(_ command: String, environment: [String: String]) -> URL? {
        let directories = (environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []) + defaultPathDirectories()
        var checked: Set<String> = []
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            guard checked.insert(candidate).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Locates the `node` binary the same way `resolve()` finds `pi`: explicit
    /// override, then `PATH`, then the common install locations. Needed for the
    /// OAuth login bridge, which runs a small Node script against PI's SDK.
    nonisolated func resolveNode() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["AGENT_DECK_NODE_PATH"], let url = executableURL(from: raw) {
            return url
        }
        if let pathResolved = resolveExecutableInPATH("node", environment: environment) {
            return pathResolved
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.hermes/node/bin/node",
            "\(home)/.local/bin/node",
            "\(home)/.nvm/versions/node/current/bin/node"
        ]
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: versions.map { $0.appendingPathComponent("bin/node").path })
        }
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated static func commonPiCandidates() -> [URL] {
        var paths: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        if let bunBin = environment["BUN_INSTALL_BIN"], !bunBin.isEmpty {
            paths.append(URL(fileURLWithPath: NSString(string: bunBin).expandingTildeInPath).appendingPathComponent("pi").path)
        }
        if let bunInstall = environment["BUN_INSTALL"], !bunInstall.isEmpty {
            paths.append(URL(fileURLWithPath: NSString(string: bunInstall).expandingTildeInPath).appendingPathComponent("bin/pi").path)
        }
        if let pnpmHome = environment["PNPM_HOME"], !pnpmHome.isEmpty {
            paths.append(URL(fileURLWithPath: NSString(string: pnpmHome).expandingTildeInPath).appendingPathComponent("pi").path)
        }
        paths.append(contentsOf: [
            "\(home)/.bun/bin/pi",
            "\(home)/Library/pnpm/pi",
            "\(home)/Library/Application Support/pnpm/pi",
            "\(home)/.local/share/pnpm/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi",
            "\(home)/.pi/agent/bin/pi",
            "\(home)/.volta/bin/pi",
            "\(home)/.hermes/node/bin/pi",
            "\(home)/.local/bin/pi",
            "\(home)/.npm-global/bin/pi",
            "\(home)/.npm/bin/pi",
            "\(home)/.nvm/versions/node/current/bin/pi"
        ])
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths.append(contentsOf: versions.map { $0.appendingPathComponent("bin/pi").path })
        }
        return paths.map(URL.init(fileURLWithPath:))
    }
}
