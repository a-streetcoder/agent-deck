import CryptoKit
import Foundation

/// Resolves Agent Deck's integrity-pinned `codex-computer-use-mcp` derivative,
/// which routes calls through OpenAI's signed Codex app-server. Agent Deck never
/// invokes the raw Sky helper directly because the service rejects non-OpenAI
/// responsible processes.
nonisolated enum CodexComputerUseBrokerDiscovery {
    static let packageName = "codex-computer-use-mcp"
    static let requiredVersion = "0.2.0"
    static let upstreamPackageDigest = "5ca2b51c934c0f961bb52644ac430dd89a3dcbc772faaae6861f05030f97ab94"
    static let variantRevision = "0.2.0-agent-deck-auto-accept.2"
    /// Canonical SHA-256 of the reviewed Agent Deck variant, including pinned
    /// runtime dependencies, modification notice, and symlink targets.
    static let requiredPackageDigest = "8a0343806c8f90f06f8d762aaf9fd3574987555df7cbee90446859396b183c78"
    static let auditFileMaxBytes = 5 * 1024 * 1024
    static let auditBackupCount = 1

    private struct VariantManifest: Decodable {
        let variant: String
        let package: String
        let upstreamVersion: String
        let upstreamDigest: String
        let packageTreeDigest: String
        let approvalHandling: String
        let auditFileMaxBytes: Int
        let auditBackupCount: Int
    }

    struct Broker: Hashable, Sendable {
        let nodeURL: URL
        let serverScriptURL: URL
        let packageRootURL: URL
        let stateRootURL: URL

        var config: MCPServerConfig {
            MCPServerConfig(
                command: nodeURL.path,
                args: [serverScriptURL.path],
                env: ["CODEX_COMPUTER_USE_HOME": stateRootURL.path],
                cwd: packageRootURL.path,
                lifecycle: .lazy
            )
        }
    }

    enum Result: Hashable, Sendable {
        case available(Broker)
        case unavailable(String)
    }

    static func discover(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = nil,
        candidatePackageRoots: [URL]? = nil,
        nodeURL: URL? = PiExecutableResolver().resolveNode(),
        nodeMajorVersionProvider: @Sendable (URL) -> Int? = nodeMajorVersion,
        expectedPackageDigest: String = requiredPackageDigest,
        fileManager: FileManager = .default
    ) -> Result {
        guard let nodeURL, fileManager.isExecutableFile(atPath: nodeURL.path) else {
            return .unavailable("Computer Use requires Node.js 22 or newer, resolved alongside Pi.")
        }
        guard let nodeMajorVersion = nodeMajorVersionProvider(nodeURL), nodeMajorVersion >= 22 else {
            return .unavailable("Computer Use requires Node.js 22 or newer; the resolved Node.js runtime is too old or could not be verified.")
        }

        let supportRoot = applicationSupportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let candidates = candidatePackageRoots ?? [
            supportRoot?
                .appendingPathComponent("Pi Deck/Computer Use Broker/Variants", isDirectory: true)
                .appendingPathComponent(variantRevision, isDirectory: true)
                .appendingPathComponent("node_modules/\(packageName)", isDirectory: true),
        ].compactMap { $0 }

        for rawCandidate in candidates {
            let candidate = rawCandidate.standardizedFileURL.resolvingSymlinksInPath()
            let packageJSON = candidate.appendingPathComponent("package.json")
            let serverScript = candidate.appendingPathComponent("dist/mcp-server.js")
            let variantManifestURL = candidate
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("agent-deck-variant.json")
            guard fileManager.isReadableFile(atPath: packageJSON.path),
                  fileManager.isReadableFile(atPath: serverScript.path),
                  let data = try? Data(contentsOf: packageJSON),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["name"] as? String == packageName,
                  object["version"] as? String == requiredVersion,
                  let manifestData = try? Data(contentsOf: variantManifestURL),
                  let manifest = try? JSONDecoder().decode(VariantManifest.self, from: manifestData),
                  manifest.variant == variantRevision,
                  manifest.package == packageName,
                  manifest.upstreamVersion == requiredVersion,
                  manifest.upstreamDigest == upstreamPackageDigest,
                  manifest.packageTreeDigest == expectedPackageDigest,
                  manifest.approvalHandling == "auto-accept",
                  manifest.auditFileMaxBytes == auditFileMaxBytes,
                  manifest.auditBackupCount == auditBackupCount,
                  packageTreeDigest(at: candidate, fileManager: fileManager) == expectedPackageDigest else { continue }

            let stateRoot = (supportRoot ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true))
                .appendingPathComponent("Pi Deck/Computer Use Broker/State/auto-accept.1", isDirectory: true)
            return .available(.init(
                nodeURL: nodeURL,
                serverScriptURL: serverScript,
                packageRootURL: candidate,
                stateRootURL: stateRoot
            ))
        }

        let target = (supportRoot ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("Pi Deck/Computer Use Broker/Variants/\(variantRevision)", isDirectory: true).path
        return .unavailable(
            "Computer Use requires Agent Deck's verified auto-accept broker variant at \(target). Install the variant described in Computer Use setup, then refresh MCP."
        )
    }

    static func packageTreeDigest(at packageRoot: URL, fileManager: FileManager = .default) -> String? {
        let root = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: root.path) else { return nil }
        var entries: [(path: String, url: URL, isSymbolicLink: Bool)] = []
        for relativePath in subpaths {
            let url = root.appendingPathComponent(relativePath)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else { return nil }
            guard type == .typeRegular || type == .typeSymbolicLink else { continue }
            entries.append((relativePath, url, type == .typeSymbolicLink))
        }

        var digest = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            digest.update(data: Data(entry.path.utf8))
            digest.update(data: Data([0]))
            if entry.isSymbolicLink {
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: entry.url.path) else { return nil }
                digest.update(data: Data("L".utf8))
                digest.update(data: Data(destination.utf8))
            } else {
                guard let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) else { return nil }
                digest.update(data: Data("F".utf8))
                digest.update(data: data)
            }
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func nodeMajorVersion(at nodeURL: URL) -> Int? {
        let process = Process()
        let output = Pipe()
        process.executableURL = nodeURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let major = value.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            return Int(major)
        } catch {
            return nil
        }
    }
}
