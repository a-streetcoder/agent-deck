import Foundation

/// A coarse classification of a project, derived from marker files in its root.
/// Drives the fallback project icon and informs dev-server command detection.
nonisolated enum ProjectType: String, CaseIterable, Sendable {
    case xcode
    case nextjs
    case tauri
    case electron
    case swiftPackage
    case go
    case rust
    case python
    case ruby
    case staticSite
    case node
    case unknown

    /// SF Symbol shown when no custom artwork asset is available.
    var sfSymbolFallback: String {
        switch self {
        case .xcode: return "apple.logo"
        case .nextjs: return "globe"
        case .tauri, .electron: return "macwindow"
        case .swiftPackage: return "shippingbox"
        case .go: return "chevron.left.forwardslash.chevron.right"
        case .rust: return "gearshape.2"
        case .python: return "terminal"
        case .ruby: return "diamond"
        case .staticSite: return "doc.richtext"
        case .node: return "curlybraces"
        case .unknown: return "folder"
        }
    }

    /// Name of the `Assets.xcassets` entry to use when present. No per-type
    /// artwork ships today — `ProjectIconView` falls back to `sfSymbolFallback`
    /// until an asset with this name is added, at which point it upgrades
    /// automatically with no code change.
    var assetName: String? {
        switch self {
        case .unknown: return nil
        default: return "project-\(rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .xcode: return "Xcode"
        case .nextjs: return "Next.js"
        case .tauri: return "Tauri"
        case .electron: return "Electron"
        case .swiftPackage: return "Swift Package"
        case .go: return "Go"
        case .rust: return "Rust"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .staticSite: return "Static Site"
        case .node: return "Node"
        case .unknown: return "Project"
        }
    }

    /// Classifies the project at `url` by probing for marker files, returning the
    /// first match in priority order (most specific first). `hasXcodeProject`
    /// is supplied by the caller so the recursive `.xcodeproj`/`.xcworkspace`
    /// descendant scan stays in `ProjectDiscovery`.
    static func detect(
        at url: URL,
        fileManager: FileManager = .default,
        hasXcodeProject: () -> Bool
    ) -> ProjectType {
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent(name).path)
        }
        func existsAny(_ names: [String]) -> Bool {
            names.contains(where: exists)
        }

        if hasXcodeProject() {
            return .xcode
        }
        if existsAny(["next.config.js", "next.config.mjs", "next.config.ts"]) {
            return .nextjs
        }
        if exists("tauri.conf.json") {
            return .tauri
        }
        if existsAny(["electron-builder.json", "electron.vite.config.ts"]) {
            return .electron
        }
        if exists("Package.swift") {
            return .swiftPackage
        }
        if exists("go.mod") {
            return .go
        }
        if exists("Cargo.toml") {
            return .rust
        }
        if existsAny(["pyproject.toml", "requirements.txt", "manage.py", "setup.py", "Pipfile"]) {
            return .python
        }
        if existsAny(["Gemfile", "Rakefile", ".ruby-version"]) {
            return .ruby
        }
        // Static-site generator configs are specific enough to win over a bare
        // package.json; a plain `index.html` is only a last resort below.
        if existsAny(["_config.yml", "astro.config.mjs", "astro.config.js", "astro.config.ts", "mkdocs.yml"]) {
            return .staticSite
        }
        if exists("package.json") {
            return .node
        }
        if exists("index.html") {
            return .staticSite
        }
        return .unknown
    }
}
