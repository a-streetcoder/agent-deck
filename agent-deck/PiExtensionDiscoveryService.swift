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
                let path = source.standardizedFileURL.path
                return PiExtensionCandidate(
                    id: candidateID(for: path),
                    // Prefer npm package name over folder segments like `src` / `extensions`.
                    name: packageExtensionDisplayName(
                        packageName: packageName,
                        packageDirectory: packageDirectory,
                        launchSource: path
                    ),
                    launchSource: path,
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
            return isExtensionEntryFile(location) ? [location] : []
        }

        // Prefer TS, then JS (e.g. pi-blackhole ships `dist/index.js`).
        for fileName in ["index.ts", "index.js", "index.mjs"] {
            let index = location.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: index.path) {
                return [index]
            }
        }

        guard let children = try? fileManager.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) else { return [] }
        return children.flatMap { child -> [URL] in
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { return [] }
            if childIsDirectory.boolValue {
                for fileName in ["index.ts", "index.js", "index.mjs"] {
                    let childIndex = child.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: childIndex.path) {
                        return [childIndex]
                    }
                }
                return []
            }
            return isExtensionEntryFile(child) ? [child] : []
        }
    }

    /// Whether a file path is a Pi-loadable extension entry (TS or JS).
    ///
    /// - Parameter url: Candidate file URL. Required.
    /// - Returns: `true` for `.ts` / `.js` / `.mjs` sources.
    private func isExtensionEntryFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ts" || ext == "js" || ext == "mjs"
    }

    /// Human label for a package-declared extension path.
    ///
    /// Uses the npm package base name (`pi-ocr`, `pi-fff`) instead of intermediate
    /// folders (`extensions`, `src`, `dist`) that previously became the list title.
    ///
    /// - Parameters:
    ///   - packageName: npm package name (`@scope/name` or bare). Required.
    ///   - packageDirectory: Resolved package root. Required.
    ///   - launchSource: Absolute path to the entry file. Required.
    /// - Returns: Display name for the Extensions checklist.
    private func packageExtensionDisplayName(
        packageName: String,
        packageDirectory: URL,
        launchSource: String
    ) -> String {
        PiExtensionDisplayNaming.packageExtensionDisplayName(
            packageName: packageName,
            packageDirectory: packageDirectory,
            launchSource: launchSource,
            pathDisplayName: { displayName(for: $0) }
        )
    }

    /// `@scope/name` → `name`; bare package → itself.
    ///
    /// - Parameter packageName: Full package name. Required.
    /// - Returns: Unscoped base name for UI.
    private func unscopedPackageBaseName(_ packageName: String) -> String {
        PiExtensionDisplayNaming.unscopedPackageBaseName(packageName)
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
        let file = url.lastPathComponent.lowercased()
        // index.* → parent folder, but skip non-descriptive parents (src/extensions/dist).
        if file == "index.ts" || file == "index.js" || file == "index.mjs" {
            var folder = url.deletingLastPathComponent()
            let skip: Set<String> = ["src", "extensions", "dist", "lib", "build"]
            while skip.contains(folder.lastPathComponent.lowercased()),
                  folder.pathComponents.count > 1 {
                let parent = folder.deletingLastPathComponent()
                if parent.path == folder.path { break }
                folder = parent
            }
            return folder.lastPathComponent
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
        var names = PiNativeSubagentBridgeExtensions.allBridgeToolNames
            .filter { name in
                // Match the name as a quoted string literal — single or double quotes.
                // This catches `server.tool("web_search", …)` and `name: 'web_search'`
                // while ignoring coincidental substring matches like variable names.
                source.contains("\"\(name)\"") || source.contains("'\(name)'")
            }
        // MCP adapter extensions (pi-mcp-adapter / pi-mcp-extension) don't register a
        // tool literally named "mcp"; they register prefixed tools like "mcp_<server>_<tool>"
        // and/or a "/mcp" command. Treat either as a conflict with the native MCP bridge,
        // surfaced under the synthetic name "mcp" so the existing warning row renders.
        if source.contains("\"mcp_") || source.contains("'mcp_")
            || source.contains("\"/mcp") || source.contains("'/mcp")
            || source.contains("\"mcp:") || source.contains("'mcp:") {
            names.insert(PiNativeSubagentBridgeExtensions.mcpProxyToolName)
        }
        return names.sorted()
    }
}

/// Extracts a short human description from a Pi extension's TypeScript source —
/// the first line of a leading `/** … */` block comment (or `//` line comment).
/// Most Pi extensions open with a JSDoc title line; returns nil when there is no
/// leading comment so the UI just shows the name. Performs synchronous file I/O.
nonisolated enum PiExtensionDescriptionReader {
    static func leadingDescription(forFile path: String) -> String? {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return leadingDescription(fromSource: source)
    }

    static func leadingDescription(fromSource source: String) -> String? {
        let trimmed = source.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        if trimmed.hasPrefix("/*") {
            guard let end = trimmed.range(of: "*/") else { return nil }
            for raw in trimmed[trimmed.startIndex..<end.lowerBound].split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                for prefix in ["/**", "/*", "*"] where line.hasPrefix(prefix) {
                    line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                if !line.isEmpty { return line }
            }
            return nil
        }
        if trimmed.hasPrefix("//") {
            let first = trimmed.split(separator: "\n").first.map(String.init) ?? ""
            let line = first.drop { $0 == "/" }.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        return nil
    }
}
