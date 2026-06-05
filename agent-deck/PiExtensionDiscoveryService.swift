import Foundation

nonisolated struct PiExtensionCandidate: Identifiable, Hashable, Sendable {
    enum DiscoveryKind: String, Sendable {
        case autoDirectory
        case settingsExtension
        case package
    }

    let id: String
    let name: String
    let launchSource: String
    let source: ScopeID
    let discoveryKind: DiscoveryKind
    let packageName: String?

    var scopeLabel: String {
        switch source.kind {
        case .global:
            return "Global"
        case .project, .legacyProject:
            return "Project"
        case .package:
            return "Package"
        default:
            return source.kind.rawValue
        }
    }

    var detailLabel: String {
        if let packageName, !packageName.isEmpty {
            return packageName
        }
        switch discoveryKind {
        case .autoDirectory:
            return "Auto-discovered"
        case .settingsExtension:
            return "settings.json"
        case .package:
            return "Package"
        }
    }
}

nonisolated struct PiExtensionDiscoveryService: @unchecked Sendable {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(fileManager: FileManager = .default, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func discover(projectRoot: URL?) -> [PiExtensionCandidate] {
        let globalSettingsURL = homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
        let projectSettingsURL = projectRoot?
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")

        var candidates: [PiExtensionCandidate] = []
        candidates += discoverAutoExtensions(
            at: homeDirectory.appendingPathComponent(".pi/agent/extensions", isDirectory: true),
            scope: ScopeID(kind: .global, path: homeDirectory.appendingPathComponent(".pi/agent/extensions", isDirectory: true).path)
        )
        if let projectRoot {
            let projectExtensions = projectRoot.appendingPathComponent(".pi/extensions", isDirectory: true)
            candidates += discoverAutoExtensions(
                at: projectExtensions,
                scope: ScopeID(kind: .project, path: projectExtensions.path)
            )
        }

        for (settingsURL, scopeKind) in [(globalSettingsURL, ResourceScopeKind.global), (projectSettingsURL, ResourceScopeKind.project)] {
            guard let settingsURL else { continue }
            let settings = parseSettings(at: settingsURL)
            let scope = ScopeID(kind: scopeKind, path: settingsURL.path)

            for source in settings.extensions {
                let resolved = resolveRelativePath(source, baseDirectory: settingsURL.deletingLastPathComponent()).standardizedFileURL
                candidates.append(PiExtensionCandidate(
                    id: candidateID(for: resolved.path),
                    name: displayName(for: resolved.path),
                    launchSource: resolved.path,
                    source: scope,
                    discoveryKind: .settingsExtension,
                    packageName: nil
                ))
            }

            for packageRef in settings.packages {
                candidates += discoverPackageExtensions(
                    packageRef: packageRef,
                    projectRoot: scopeKind == .project ? projectRoot : nil,
                    scope: ScopeID(kind: .package, path: packageRef)
                )
            }
        }

        return dedupe(candidates).sorted { lhs, rhs in
            let rankOrder = scopeRank(lhs.source.kind) - scopeRank(rhs.source.kind)
            if rankOrder != 0 { return rankOrder < 0 }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.launchSource < rhs.launchSource
        }
    }

    func enabledCandidates(settings: AppSettings, projectRoot: URL?) -> [PiExtensionCandidate] {
        discover(projectRoot: projectRoot).filter { !settings.disabledPiExtensionIDs.contains($0.id) }
    }

    // MARK: - Discovery

    private func discoverAutoExtensions(at directory: URL, scope: ScopeID) -> [PiExtensionCandidate] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var candidates: [PiExtensionCandidate] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let index = url.appendingPathComponent("index.ts")
                guard fileManager.fileExists(atPath: index.path) else { continue }
                candidates.append(PiExtensionCandidate(
                    id: candidateID(for: index.standardizedFileURL.path),
                    name: url.lastPathComponent,
                    launchSource: index.standardizedFileURL.path,
                    source: scope,
                    discoveryKind: .autoDirectory,
                    packageName: nil
                ))
            } else if url.pathExtension == "ts" {
                candidates.append(PiExtensionCandidate(
                    id: candidateID(for: url.standardizedFileURL.path),
                    name: url.deletingPathExtension().lastPathComponent,
                    launchSource: url.standardizedFileURL.path,
                    source: scope,
                    discoveryKind: .autoDirectory,
                    packageName: nil
                ))
            }
        }
        return candidates
    }

    private func discoverPackageExtensions(packageRef: String, projectRoot: URL?, scope: ScopeID) -> [PiExtensionCandidate] {
        guard let packageDirectory = resolvePackageDirectory(for: packageRef, projectRoot: projectRoot) else { return [] }
        let packageName = packageDisplayName(packageRef)
        let locations = resolvePackageExtensionLocations(packageDirectory: packageDirectory)
        return locations.flatMap { location -> [PiExtensionCandidate] in
            concreteExtensionLaunchSources(at: location).map { source in
                PiExtensionCandidate(
                    id: candidateID(for: source.standardizedFileURL.path),
                    name: displayName(for: source.path),
                    launchSource: source.standardizedFileURL.path,
                    source: ScopeID(kind: .package, path: packageDirectory.path),
                    discoveryKind: .package,
                    packageName: packageName
                )
            }
        }
    }

    private func concreteExtensionLaunchSources(at location: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return location.pathExtension == "ts" ? [location] : []
        }

        let index = location.appendingPathComponent("index.ts")
        if fileManager.fileExists(atPath: index.path) {
            return [index]
        }

        guard let children = try? fileManager.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) else { return [] }
        return children.flatMap { child -> [URL] in
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { return [] }
            if childIsDirectory.boolValue {
                let childIndex = child.appendingPathComponent("index.ts")
                return fileManager.fileExists(atPath: childIndex.path) ? [childIndex] : []
            }
            return child.pathExtension == "ts" ? [child] : []
        }
    }

    private struct ParsedSettings {
        let extensions: [String]
        let packages: [String]
    }

    private func parseSettings(at url: URL) -> ParsedSettings {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedSettings(extensions: [], packages: [])
        }
        return ParsedSettings(
            extensions: stringList(from: root["extensions"]),
            packages: packageSources(from: root["packages"])
        )
    }

    private func stringList(from value: Any?) -> [String] {
        if let value = value as? String { return value.isEmpty ? [] : [value] }
        if let values = value as? [Any] {
            return values.compactMap { ($0 as? String)?.nonEmpty }
        }
        return []
    }

    private func packageSources(from value: Any?) -> [String] {
        guard let packages = value as? [Any] else { return [] }
        return packages.compactMap { package in
            if let source = package as? String { return source.nonEmpty }
            return (package as? [String: Any])?["source"] as? String
        }
    }

    private func resolvePackageExtensionLocations(packageDirectory: URL) -> [URL] {
        let packageJSON = packageDirectory.appendingPathComponent("package.json")
        var declared: [String] = []
        if let data = try? Data(contentsOf: packageJSON),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pi = root["pi"] as? [String: Any] {
            declared = stringList(from: pi["extensions"])
        }

        let locations = declared.isEmpty
            ? [packageDirectory.appendingPathComponent("extensions", isDirectory: true)]
            : declared.map { resolveRelativePath($0, baseDirectory: packageDirectory) }
        var seen: Set<String> = []
        return locations.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resolvePackageDirectory(for packageReference: String, projectRoot: URL?) -> URL? {
        let expanded = NSString(string: packageReference).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        if expanded.hasPrefix(".") {
            guard let projectRoot else { return nil }
            let url = projectRoot.appendingPathComponent(expanded, isDirectory: true)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let packageName = npmPackageName(packageReference) ?? packageDisplayName(packageReference)
        let candidates = [
            homeDirectory.appendingPathComponent(".pi/agent/npm/node_modules/\(packageName)", isDirectory: true),
            projectRoot?.appendingPathComponent(".pi/npm/node_modules/\(packageName)", isDirectory: true),
            gitPackageDirectory(packageReference: packageReference, projectRoot: projectRoot),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(packageName)", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(packageName)", isDirectory: true),
            homeDirectory.appendingPathComponent(".npm-global/lib/node_modules/\(packageName)", isDirectory: true),
            homeDirectory.appendingPathComponent("node_modules/\(packageName)", isDirectory: true),
            projectRoot?.appendingPathComponent("node_modules/\(packageName)", isDirectory: true)
        ].compactMap { $0 }

        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private func gitPackageDirectory(packageReference: String, projectRoot: URL?) -> URL? {
        let raw: String
        if packageReference.hasPrefix("git:") {
            raw = String(packageReference.dropFirst(4))
        } else if packageReference.hasPrefix("https://") || packageReference.hasPrefix("http://") || packageReference.hasPrefix("ssh://") {
            raw = packageReference
        } else {
            return nil
        }

        let withoutScheme = raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "ssh://git@", with: "")
            .replacingOccurrences(of: "git@", with: "")
            .replacingOccurrences(of: ":", with: "/")
        let withoutRef = withoutScheme.split(separator: "@").first.map(String.init) ?? withoutScheme
        let trimmed = withoutRef.hasSuffix(".git") ? String(withoutRef.dropLast(4)) : withoutRef
        let global = homeDirectory.appendingPathComponent(".pi/agent/git/\(trimmed)", isDirectory: true)
        if fileManager.fileExists(atPath: global.path) { return global }
        if let projectRoot {
            let project = projectRoot.appendingPathComponent(".pi/git/\(trimmed)", isDirectory: true)
            if fileManager.fileExists(atPath: project.path) { return project }
        }
        return nil
    }

    private func npmPackageName(_ reference: String) -> String? {
        guard reference.hasPrefix("npm:") else { return nil }
        var name = String(reference.dropFirst(4))
        if name.hasPrefix("@") {
            let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return name }
            if let at = parts[1].lastIndex(of: "@") {
                name = parts[0] + "/" + String(parts[1][..<at])
            }
            return name
        }
        if let at = name.lastIndex(of: "@") {
            name = String(name[..<at])
        }
        return name
    }

    private func packageDisplayName(_ reference: String) -> String {
        if let npm = npmPackageName(reference) { return npm }
        if reference.hasPrefix("git:") { return String(reference.dropFirst(4)) }
        return SlashCommandCatalog.normalizePackageReference(reference)
    }

    private func resolveRelativePath(_ path: String, baseDirectory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return baseDirectory.appendingPathComponent(expanded)
    }

    private func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "index.ts" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func candidateID(for path: String) -> String {
        "path:" + URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func dedupe(_ candidates: [PiExtensionCandidate]) -> [PiExtensionCandidate] {
        var seen: Set<String> = []
        var result: [PiExtensionCandidate] = []
        for candidate in candidates where seen.insert(candidate.id).inserted {
            result.append(candidate)
        }
        return result
    }

    private func scopeRank(_ scope: ResourceScopeKind) -> Int {
        switch scope {
        case .global: return 0
        case .project, .legacyProject: return 1
        case .package: return 2
        default: return 3
        }
    }
}

/// Scans a Pi extension's TypeScript source for tool name registrations that
/// overlap with tool names Agent Deck may register through built-in bridges.
///
/// Uses a simple quoted-string scan — conservative and fast. False positives
/// (e.g. a comment that mentions a tool name) are acceptable; false negatives
/// (dynamically computed tool names) are ignored by design. Some Agent Deck
/// bridge tools are conditional per launch, so detections are potential conflicts.
/// When the source file cannot be read the detector fails open, returning no
/// conflicts so the UI never produces a spurious warning from a read error.
nonisolated struct PiExtensionConflictDetector: @unchecked Sendable {
    /// Returns bridge tool names detected in the TypeScript source of `candidate`.
    /// Performs synchronous file I/O; call from a background context when batching
    /// across many candidates.
    static func conflictingBridgeToolNames(for candidate: PiExtensionCandidate) -> [String] {
        guard let source = try? String(contentsOfFile: candidate.launchSource, encoding: .utf8) else {
            return []
        }
        return PiNativeSubagentBridgeExtensions.allBridgeToolNames
            .filter { name in
                // Match the name as a quoted string literal — single or double quotes.
                // This catches `server.tool("web_search", …)` and `name: 'web_search'`
                // while ignoring coincidental substring matches like variable names.
                source.contains("\"\(name)\"") || source.contains("'\(name)'")
            }
            .sorted()
    }
}
