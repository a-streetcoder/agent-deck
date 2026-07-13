import Foundation

/// Read-only discovery for Codex's locally installed plugin cache.
nonisolated enum CodexPluginSkillDiscovery {
    struct PluginIdentity: Codable, Hashable, Sendable {
        let marketplace: String
        let plugin: String
        var configKey: String { "\(plugin)@\(marketplace)" }
        var isSafe: Bool { Self.safeSegment(marketplace) && Self.safeSegment(plugin) }
        private static func safeSegment(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
        }
    }

    struct Package: Hashable, Sendable {
        let identity: PluginIdentity
        let version: String
        let root: URL
        let skillsRoot: URL
        let displayName: String
    }

    static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Select exactly as Codex's PluginStore does, then validate that one package.
    /// A malformed newest package is unavailable; it never falls back to old cache data.
    static func activePackages(codexHome: URL = codexHome()) -> [Package] {
        let cache = codexHome.appendingPathComponent("plugins/cache", isDirectory: true)
        let configured = configuredPluginKeys(at: codexHome.appendingPathComponent("config.toml"))
        guard let marketplaces = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) else { return [] }
        return marketplaces.filter(isDirectory).flatMap { marketplaceURL -> [Package] in
            guard let plugins = try? FileManager.default.contentsOfDirectory(at: marketplaceURL, includingPropertiesForKeys: nil) else { return [] }
            return plugins.filter(isDirectory).compactMap { pluginURL in
                let identity = PluginIdentity(marketplace: marketplaceURL.lastPathComponent, plugin: pluginURL.lastPathComponent)
                guard identity.isSafe,
                      configured.contains(identity.configKey) || validRemoteMarker(at: pluginURL) else { return nil }
                let versions = (try? FileManager.default.contentsOfDirectory(at: pluginURL, includingPropertiesForKeys: nil))?.filter { isDirectory($0) && validVersionSegment($0.lastPathComponent) } ?? []
                guard let selected = versions.sorted(by: versionPrecedes).first else { return nil }
                return package(at: selected, identity: identity)
            }
        }.sorted { $0.identity.configKey < $1.identity.configKey }
    }

    static func resolve(_ reference: CodexPluginSkillReference, codexHome: URL = codexHome()) -> URL? {
        resolveAll([reference], codexHome: codexHome)[reference]
    }

    /// Resolves a batch from one active-package scan, avoiding a cache walk per skill.
    static func resolveAll(_ references: Set<CodexPluginSkillReference>, codexHome: URL = codexHome()) -> [CodexPluginSkillReference: URL] {
        guard !references.isEmpty else { return [:] }
        let packages = Dictionary(uniqueKeysWithValues: activePackages(codexHome: codexHome).map { ($0.identity, $0) })
        return Dictionary(uniqueKeysWithValues: references.compactMap { reference in
            let identity = PluginIdentity(marketplace: reference.marketplace, plugin: reference.plugin)
            guard identity.isSafe, let package = packages[identity], let relative = safeRelativePath(reference.relativeSkillRoot) else { return nil }
            let root = package.skillsRoot.appendingPathComponent(relative, isDirectory: true)
            let skillFile = root.appendingPathComponent("SKILL.md")
            guard canonicalContained(root, in: package.skillsRoot),
                  canonicalContained(skillFile, in: package.skillsRoot),
                  FileManager.default.fileExists(atPath: skillFile.path) else { return nil }
            return (reference, root.standardizedFileURL)
        })
    }

    static func pluginBaseDirectory(for reference: CodexPluginSkillReference, codexHome: URL = codexHome()) -> URL? {
        let identity = PluginIdentity(marketplace: reference.marketplace, plugin: reference.plugin)
        guard identity.isSafe else { return nil }
        return codexHome.appendingPathComponent("plugins/cache/\(identity.marketplace)/\(identity.plugin)", isDirectory: true)
    }

    static func candidateReferences(codexHome: URL = codexHome()) async -> [(ExternalSkillCandidate, CodexPluginSkillReference, Package)] {
        var result: [(ExternalSkillCandidate, CodexPluginSkillReference, Package)] = []
        for package in activePackages(codexHome: codexHome) {
            for candidate in await ExternalSkillDiscovery.discover(root: package.skillsRoot) {
                let root = URL(fileURLWithPath: candidate.sourceRootPath)
                let skillFile = URL(fileURLWithPath: candidate.skillFilePath)
                guard canonicalContained(root, in: package.skillsRoot),
                      canonicalContained(skillFile, in: package.skillsRoot) else { continue }
                let relative: String
                if root.standardizedFileURL.path == package.skillsRoot.standardizedFileURL.path { relative = "." }
                else { relative = String(root.standardizedFileURL.path.dropFirst(package.skillsRoot.standardizedFileURL.path.count + 1)) }
                result.append((candidate, .init(marketplace: package.identity.marketplace, plugin: package.identity.plugin, relativeSkillRoot: relative), package))
            }
        }
        return result
    }

    private static func package(at root: URL, identity: PluginIdentity) -> Package? {
        let manifestURL = root.appendingPathComponent(".codex-plugin/plugin.json")
        guard canonicalContained(manifestURL, in: root),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name == identity.plugin else { return nil }
        let paths = (manifest["skills"] as? String).map { [$0] } ?? (manifest["skills"] as? [String] ?? [])
        if let declared = manifest["version"] as? String, semVer(root.lastPathComponent) != nil, declared != root.lastPathComponent { return nil }
        guard paths.count == 1, let relative = safeRelativePath(paths[0]) else { return nil }
        let skillsRoot = root.appendingPathComponent(relative, isDirectory: true)
        guard canonicalContained(skillsRoot, in: root), isDirectory(skillsRoot) else { return nil }
        let displayName = ((manifest["interface"] as? [String: Any])?["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Package(identity: identity, version: root.lastPathComponent, root: root.standardizedFileURL, skillsRoot: skillsRoot.standardizedFileURL, displayName: displayName?.isEmpty == false ? displayName! : name)
    }

    private static func validRemoteMarker(at pluginBase: URL) -> Bool {
        let url = pluginBase.appendingPathComponent(".codex-remote-plugin-install.json")
        guard canonicalContained(url, in: pluginBase),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? Int == 1,
              let id = (object["remote_plugin_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return false }
        return true
    }

    private static func configuredPluginKeys(at url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let pattern = #"^\s*\[\s*plugins\s*\.\s*\"([^\"]+)\"\s*\]\s*(?:#.*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[keyRange])
        })
    }

    private static func versionPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.lastPathComponent, right = rhs.lastPathComponent
        if left == "local" { return right != "local" }
        if right == "local" { return false }
        if let a = semVer(left), let b = semVer(right), a != b { return a > b }
        return left > right
    }

    private struct SemVer: Comparable, Equatable {
        let core: [Int]; let prerelease: [String]?
        static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            for (a, b) in zip(lhs.core, rhs.core) where a != b { return a < b }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (nil, _): return false // stable > prerelease
            case (_, nil): return true
            case let (a?, b?):
                for (left, right) in zip(a, b) where left != right {
                    let li = Int(left), ri = Int(right)
                    if let li, let ri { return li < ri }
                    if li != nil { return true }
                    if ri != nil { return false }
                    return left < right
                }
                return a.count < b.count
            }
        }
    }
    private static func semVer(_ value: String) -> SemVer? {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2, !buildParts.contains(where: { $0.isEmpty }),
              buildParts.dropFirst().allSatisfy({ $0.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(validIdentifier) }) else { return nil }
        let pieces = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2, !pieces.contains(where: { $0.isEmpty }) else { return nil }
        let coreParts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3, coreParts.allSatisfy(validNumericIdentifier) else { return nil }
        let core = coreParts.compactMap { Int($0) }
        guard core.count == 3 else { return nil }
        let prereleaseParts = pieces.count == 2 ? pieces[1].split(separator: ".", omittingEmptySubsequences: false) : []
        guard prereleaseParts.allSatisfy(validIdentifier),
              !prereleaseParts.contains(where: { $0.allSatisfy(\.isNumber) && !validNumericIdentifier($0) }) else { return nil }
        return SemVer(core: core, prerelease: pieces.count == 2 ? prereleaseParts.map(String.init) : nil)
    }
    private static func validIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) }
    }
    private static func validNumericIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber } && (value.count == 1 || value.first != "0")
    }
    /// Mirrors Codex PluginStore's `validate_plugin_version_segment` guard.
    private static func validVersionSegment(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || ".+_-".unicodeScalars.contains($0)
        }
    }
    private static func safeRelativePath(_ value: String) -> String? {
        guard value == "." || (!value.isEmpty && !value.hasPrefix("/") && !value.split(separator: "/").contains("..")) else { return nil }
        return value
    }
    private static func canonicalContained(_ child: URL, in parent: URL) -> Bool {
        let child = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return child == parent || child.hasPrefix(parent + "/")
    }
    private static func isDirectory(_ url: URL) -> Bool { var value: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue }
}
