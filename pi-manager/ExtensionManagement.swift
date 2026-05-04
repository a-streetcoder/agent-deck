import Darwin
import Foundation

struct PiExtensionRecord: Identifiable, Hashable {
    enum Scope: String, Hashable {
        case global = "Global"
        case project = "Project"
    }

    enum Origin: String, Hashable {
        case auto = "Auto-discovered"
        case settings = "Settings"
        case package = "Package"
    }

    let id: String
    let displayName: String
    let path: String
    let relativePattern: String
    let enabled: Bool
    let scope: Scope
    let origin: Origin
    let settingsPath: String
    let packageSource: String?

    var sourceSummary: String {
        switch origin {
        case .auto:
            return scope == .global ? "~/.pi/agent/extensions" : ".pi/extensions"
        case .settings:
            return URL(fileURLWithPath: settingsPath).lastPathComponent
        case .package:
            return packageSource ?? "Package"
        }
    }
}

struct PiExtensionManagementService {
    private let fileManager = FileManager.default

    func scan(projectRoot: URL?) -> [PiExtensionRecord] {
        var records: [PiExtensionRecord] = []
        var seen = Set<String>()
        let globalSettings = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
        let projectSettings = projectRoot?.appendingPathComponent(".pi/settings.json")

        records.append(contentsOf: scanTopLevel(scope: .project, projectRoot: projectRoot, settingsURL: projectSettings, seen: &seen))
        records.append(contentsOf: scanTopLevel(scope: .global, projectRoot: nil, settingsURL: globalSettings, seen: &seen))
        records.append(contentsOf: scanPackages(settingsURL: projectSettings, scope: .project, projectRoot: projectRoot, seen: &seen))
        records.append(contentsOf: scanPackages(settingsURL: globalSettings, scope: .global, projectRoot: projectRoot, seen: &seen))

        return records.sorted {
            if $0.enabled != $1.enabled { return $0.enabled && !$1.enabled }
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func setEnabled(_ record: PiExtensionRecord, enabled: Bool) throws {
        switch record.origin {
        case .auto, .settings:
            try updateTopLevelSetting(record, enabled: enabled)
        case .package:
            try updatePackageSetting(record, enabled: enabled)
        }
    }

    private func scanTopLevel(scope: PiExtensionRecord.Scope, projectRoot: URL?, settingsURL: URL?, seen: inout Set<String>) -> [PiExtensionRecord] {
        guard let settingsURL else { return [] }
        let baseDir = scope == .global
            ? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true)
            : (projectRoot?.appendingPathComponent(".pi", isDirectory: true) ?? settingsURL.deletingLastPathComponent())
        let autoDir = baseDir.appendingPathComponent("extensions", isDirectory: true)
        let settings = loadObject(at: settingsURL)
        let entries = stringArray(settings["extensions"])
        var records: [PiExtensionRecord] = []

        for url in extensionFiles(in: autoDir) {
            let pattern = relativePath(from: baseDir, to: url)
            let enabled = isEnabledByOverrides(file: url, entries: entries, baseDir: baseDir)
            addRecord(url: url, pattern: pattern, enabled: enabled, scope: scope, origin: .auto, settingsURL: settingsURL, packageSource: nil, seen: &seen, to: &records)
        }

        for entry in entries {
            let parsed = stripPrefix(entry)
            guard !parsed.value.isEmpty, parsed.prefix != "!" else { continue }
            let url = resolvePath(parsed.value, baseDir: baseDir)
            for file in extensionFiles(from: url) {
                let pattern = relativePath(from: baseDir, to: file)
                let enabled = parsed.prefix == "-" ? false : true
                addRecord(url: file, pattern: pattern, enabled: enabled, scope: scope, origin: .settings, settingsURL: settingsURL, packageSource: nil, seen: &seen, to: &records)
            }
        }

        return records
    }

    private func scanPackages(settingsURL: URL?, scope: PiExtensionRecord.Scope, projectRoot: URL?, seen: inout Set<String>) -> [PiExtensionRecord] {
        guard let settingsURL else { return [] }
        let settings = loadObject(at: settingsURL)
        let packages = (settings["packages"] as? [Any]) ?? []
        var records: [PiExtensionRecord] = []

        for package in packages {
            let source = packageSource(package)
            guard let source, let packageDir = resolvePackageDirectory(source, scope: scope, projectRoot: projectRoot) else { continue }
            let filters = (package as? [String: Any]).flatMap { stringArray($0["extensions"]) }
            let files = packageExtensionFiles(in: packageDir)
            for file in files {
                let pattern = relativePath(from: packageDir, to: file)
                let enabled = packageEnabled(pattern: pattern, filters: filters)
                addRecord(url: file, pattern: pattern, enabled: enabled, scope: scope, origin: .package, settingsURL: settingsURL, packageSource: source, seen: &seen, to: &records)
            }
        }

        return records
    }

    private func addRecord(url: URL, pattern: String, enabled: Bool, scope: PiExtensionRecord.Scope, origin: PiExtensionRecord.Origin, settingsURL: URL, packageSource: String?, seen: inout Set<String>, to records: inout [PiExtensionRecord]) {
        let key = "\(origin.rawValue):\(scope.rawValue):\(url.standardizedFileURL.path):\(packageSource ?? "")"
        guard seen.insert(key).inserted else { return }
        records.append(PiExtensionRecord(
            id: key,
            displayName: displayName(for: url),
            path: url.path,
            relativePattern: pattern,
            enabled: enabled,
            scope: scope,
            origin: origin,
            settingsPath: settingsURL.path,
            packageSource: packageSource
        ))
    }

    private func updateTopLevelSetting(_ record: PiExtensionRecord, enabled: Bool) throws {
        let settingsURL = URL(fileURLWithPath: record.settingsPath)
        var settings = loadObject(at: settingsURL)
        var entries = stringArray(settings["extensions"])
        entries.removeAll { stripPrefix($0).value == record.relativePattern }
        entries.append((enabled ? "+" : "-") + record.relativePattern)
        settings["extensions"] = entries
        try saveObject(settings, to: settingsURL)
    }

    private func updatePackageSetting(_ record: PiExtensionRecord, enabled: Bool) throws {
        guard let source = record.packageSource else { return }
        let settingsURL = URL(fileURLWithPath: record.settingsPath)
        var settings = loadObject(at: settingsURL)
        var packages = (settings["packages"] as? [Any]) ?? []
        guard let index = packages.firstIndex(where: { packageSource($0) == source }) else { return }
        var object = (packages[index] as? [String: Any]) ?? ["source": source]
        var entries = stringArray(object["extensions"])
        entries.removeAll { stripPrefix($0).value == record.relativePattern }
        entries.append((enabled ? "+" : "-") + record.relativePattern)
        object["extensions"] = entries
        packages[index] = object
        settings["packages"] = packages
        try saveObject(settings, to: settingsURL)
    }

    private func isEnabledByOverrides(file: URL, entries: [String], baseDir: URL) -> Bool {
        let overrides = entries.map(stripPrefix).filter { ["!", "+", "-"].contains($0.prefix) }
        let excludes = overrides.filter { $0.prefix == "!" }.map(\.value)
        let forceIncludes = overrides.filter { $0.prefix == "+" }.map(\.value)
        let forceExcludes = overrides.filter { $0.prefix == "-" }.map(\.value)
        var enabled = true
        if excludes.contains(where: { matchesPattern(file, pattern: $0, baseDir: baseDir) }) { enabled = false }
        if forceIncludes.contains(where: { matchesExact(file, pattern: $0, baseDir: baseDir) }) { enabled = true }
        if forceExcludes.contains(where: { matchesExact(file, pattern: $0, baseDir: baseDir) }) { enabled = false }
        return enabled
    }

    private func packageEnabled(pattern: String, filters: [String]?) -> Bool {
        guard let filters else { return true }
        if filters.isEmpty { return false }

        let parsed = filters.map(stripPrefix)
        let includes = parsed.filter { $0.prefix.isEmpty }.map(\.value)
        let excludes = parsed.filter { $0.prefix == "!" }.map(\.value)
        let forceIncludes = parsed.filter { $0.prefix == "+" }.map(\.value)
        let forceExcludes = parsed.filter { $0.prefix == "-" }.map(\.value)

        var enabled = includes.isEmpty || includes.contains { globMatches(pattern, $0) || URL(fileURLWithPath: pattern).lastPathComponent == $0 }
        if excludes.contains(where: { globMatches(pattern, $0) || URL(fileURLWithPath: pattern).lastPathComponent == $0 }) { enabled = false }
        if forceIncludes.contains(where: { exactPatternMatches(pattern, $0) }) { enabled = true }
        if forceExcludes.contains(where: { exactPatternMatches(pattern, $0) }) { enabled = false }
        return enabled
    }

    private func extensionFiles(in directory: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.flatMap { extensionFiles(from: $0) }
    }

    private func extensionFiles(from url: URL) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isRegularFile == true, ["ts", "js"].contains(url.pathExtension) { return [url] }
        if values?.isDirectory == true {
            let indexTS = url.appendingPathComponent("index.ts")
            let indexJS = url.appendingPathComponent("index.js")
            if fileManager.fileExists(atPath: indexTS.path) { return [indexTS] }
            if fileManager.fileExists(atPath: indexJS.path) { return [indexJS] }
        }
        return []
    }

    private func packageExtensionFiles(in packageDir: URL) -> [URL] {
        let manifest = packageManifest(at: packageDir)
        if let pi = manifest?["pi"] as? [String: Any] {
            let entries = stringArray(pi["extensions"])
            if !entries.isEmpty {
                return entries.flatMap { extensionFiles(from: resolvePath($0, baseDir: packageDir)) }
            }
        }
        return extensionFiles(in: packageDir.appendingPathComponent("extensions", isDirectory: true))
    }

    private func resolvePackageDirectory(_ source: String, scope: PiExtensionRecord.Scope, projectRoot: URL?) -> URL? {
        if source.hasPrefix("/") { return existingDirectory(URL(fileURLWithPath: source, isDirectory: true)) }
        if source.hasPrefix(".") {
            let base = scope == .project ? projectRoot : fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true)
            return base.flatMap { existingDirectory($0.appendingPathComponent(source, isDirectory: true)) }
        }
        let name = normalizedPackageName(source)
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)", isDirectory: true),
            projectRoot?.appendingPathComponent("node_modules/\(name)", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func normalizedPackageName(_ source: String) -> String {
        var value = source
        if value.hasPrefix("npm:") { value.removeFirst(4) }
        if let at = value.lastIndex(of: "@"), at != value.startIndex { value = String(value[..<at]) }
        return value
    }

    private func existingDirectory(_ url: URL) -> URL? {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }

    private func packageSource(_ package: Any) -> String? {
        if let source = package as? String { return source }
        return (package as? [String: Any])?["source"] as? String
    }

    private func packageManifest(at url: URL) -> [String: Any]? {
        loadObject(at: url.appendingPathComponent("package.json"))
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private func stripPrefix(_ value: String) -> (prefix: String, value: String) {
        guard let first = value.first, ["+", "-", "!"].contains(first) else { return ("", value) }
        return (String(first), String(value.dropFirst()))
    }

    private func resolvePath(_ path: String, baseDir: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return baseDir.appendingPathComponent(expanded)
    }

    private func relativePath(from base: URL, to url: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") { return String(path.dropFirst(basePath.count + 1)) }
        return path
    }

    private func displayName(for url: URL) -> String {
        if ["index.ts", "index.js"].contains(url.lastPathComponent) { return url.deletingLastPathComponent().lastPathComponent }
        return url.lastPathComponent
    }

    private func matchesPattern(_ file: URL, pattern: String, baseDir: URL) -> Bool {
        let rel = relativePath(from: baseDir, to: file)
        let absolute = file.standardizedFileURL.path
        let name = file.lastPathComponent
        return globMatches(rel, pattern) || globMatches(absolute, pattern) || globMatches(name, pattern)
    }

    private func matchesExact(_ file: URL, pattern: String, baseDir: URL) -> Bool {
        let normalized = normalizeExactPattern(pattern)
        return [relativePath(from: baseDir, to: file), file.standardizedFileURL.path]
            .map(normalizeExactPattern)
            .contains(normalized)
    }

    private func exactPatternMatches(_ path: String, _ pattern: String) -> Bool {
        normalizeExactPattern(path) == normalizeExactPattern(pattern)
    }

    private func normalizeExactPattern(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("./") { normalized.removeFirst(2) }
        return normalized
    }

    private func globMatches(_ value: String, _ pattern: String) -> Bool {
        fnmatch(normalizeExactPattern(pattern), normalizeExactPattern(value), 0) == 0
    }

    private func loadObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func saveObject(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
