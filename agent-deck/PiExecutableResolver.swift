import Foundation

struct PiExecutableResolver: Sendable {
    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedURL: (key: String, url: URL)?

    nonisolated func resolve() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let cacheKey = Self.cacheKey(for: environment)

        PiExecutableResolver.cacheLock.lock()
        if let cached = PiExecutableResolver.cachedURL, cached.key == cacheKey,
           FileManager.default.isExecutableFile(atPath: cached.url.path) {
            PiExecutableResolver.cacheLock.unlock()
            return cached.url
        }
        PiExecutableResolver.cacheLock.unlock()

        guard let resolved = resolveUncached(environment: environment) else {
            return nil
        }

        PiExecutableResolver.cacheLock.lock()
        PiExecutableResolver.cachedURL = (cacheKey, resolved)
        PiExecutableResolver.cacheLock.unlock()
        return resolved
    }

    nonisolated private static func cacheKey(for environment: [String: String]) -> String {
        [
            environment["AGENT_DECK_PI_PATH"] ?? "",
            environment["PI_CLI_PATH"] ?? "",
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

        let candidates = commonPiCandidates()
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
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let path = [environment["PATH"], defaultPath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        var checked: Set<String> = []
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            guard checked.insert(candidate).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    nonisolated func commonPiCandidates() -> [URL] {
        var paths = [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            "/usr/bin/pi"
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(contentsOf: [
            "\(home)/.pi/agent/bin/pi",
            "\(home)/.volta/bin/pi",
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
