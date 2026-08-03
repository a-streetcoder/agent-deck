import Foundation

/// Pure naming helpers for the Extensions checklist (package vs `src`/`extensions` folders).
nonisolated enum PiExtensionDisplayNaming {
    /**
     Builds a human-readable extension title for a package entry.

     Prefers the npm package base name over generic parent folders (`src`, `extensions`, `dist`).

     - Parameters:
       - packageName: npm package name (`@scope/name` or bare). Required.
       - packageDirectory: Package root directory. Required.
       - launchSource: Absolute path to the entry file. Required.
       - pathDisplayName: Fallback display name for a path. Required.
     - Returns: Checklist title string.
     */
    static func packageExtensionDisplayName(
        packageName: String,
        packageDirectory: URL,
        launchSource: String,
        pathDisplayName: (String) -> String = { path in
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            if name == "index" || name.isEmpty {
                return url.deletingLastPathComponent().lastPathComponent
            }
            return name
        }
    ) -> String {
        let base = unscopedPackageBaseName(packageName)
        let packageRoot = packageDirectory.standardizedFileURL.path
        let source = URL(fileURLWithPath: launchSource).standardizedFileURL.path
        let relative: String
        if source.hasPrefix(packageRoot + "/") {
            relative = String(source.dropFirst(packageRoot.count + 1))
        } else {
            relative = pathDisplayName(launchSource)
        }
        let entryFolderHints: Set<String> = ["src", "extensions", "dist", "lib", "build"]
        let relativeDir = URL(fileURLWithPath: relative).deletingLastPathComponent().path
        let parentHint = URL(fileURLWithPath: relative).deletingLastPathComponent().lastPathComponent
        let isDefaultLayout =
            relative == "index.ts"
            || relative == "index.js"
            || relative == "index.mjs"
            || relative.hasPrefix("src/")
            || relative.hasPrefix("extensions/")
            || relative.hasPrefix("dist/")
            || entryFolderHints.contains(parentHint)
        if isDefaultLayout || relativeDir == "." || relativeDir.isEmpty {
            return base.isEmpty ? pathDisplayName(launchSource) : base
        }
        if base.isEmpty { return pathDisplayName(launchSource) }
        return "\(base) · \(relative)"
    }

    /**
     Strips an npm scope prefix.

     - Parameter packageName: Full package name. Required.
     - Returns: Unscoped base name, or empty when input is blank.
     */
    static func unscopedPackageBaseName(_ packageName: String) -> String {
        let trimmed = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }
}
