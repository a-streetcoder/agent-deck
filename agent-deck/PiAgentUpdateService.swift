import Foundation

struct PiAgentRuntimeStatus: Hashable {
    enum UpdateState: Hashable {
        case upToDate
        case updateAvailable(latestVersion: String)
        case unableToCheck(String)
    }

    let isInstalled: Bool
    let currentVersion: String?
    let updateState: UpdateState?
    let detail: String

    static let missing = PiAgentRuntimeStatus(
        isInstalled: false,
        currentVersion: nil,
        updateState: nil,
        detail: "Install Pi and make sure `pi` is available from your login shell."
    )
}

struct PiAgentUpdateService {
    private struct LatestVersionResponse: Decodable {
        let version: String
        let packageName: String?
    }

    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver
    private let latestVersionURL = URL(string: "https://pi.dev/api/latest-version")!

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadStatus() async -> PiAgentRuntimeStatus {
        let piCommand = piResolver.resolve()?.path ?? "pi"

        let currentVersion: String
        do {
            let result = try await commandRunner.run(
                piCommand,
                arguments: ["--version"],
                currentDirectoryURL: nil,
                timeout: 6,
                environment: nil
            )
            guard result.exitCode == 0 else {
                return .missing
            }
            let rawVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedVersion = rawVersion.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : rawVersion
            guard !resolvedVersion.isEmpty else { return .missing }
            currentVersion = resolvedVersion
        } catch {
            return .missing
        }

        do {
            let latestVersion = try await latestVersion(currentVersion: currentVersion)
            if Self.isNewerVersion(latestVersion, than: currentVersion) {
                return PiAgentRuntimeStatus(
                    isInstalled: true,
                    currentVersion: currentVersion,
                    updateState: .updateAvailable(latestVersion: latestVersion),
                    detail: "A newer Pi agent release is available."
                )
            }
            return PiAgentRuntimeStatus(
                isInstalled: true,
                currentVersion: currentVersion,
                updateState: .upToDate,
                detail: "Pi is installed and up to date."
            )
        } catch {
            return PiAgentRuntimeStatus(
                isInstalled: true,
                currentVersion: currentVersion,
                updateState: .unableToCheck(error.localizedDescription),
                detail: "Pi is installed, but the latest release could not be checked."
            )
        }
    }

    private func latestVersion(currentVersion: String) async throws -> String {
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

    private static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let comparison = compareSemanticVersions(candidate, current) else {
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines) != current.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return comparison > 0
    }

    private static func compareSemanticVersions(_ lhs: String, _ rhs: String) -> Int? {
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

    private static func semanticVersion(_ version: String) -> (major: Int, minor: Int, patch: Int, prerelease: String?)? {
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
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
