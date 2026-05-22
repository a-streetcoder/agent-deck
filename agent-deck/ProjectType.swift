import Foundation

/// A coarse classification of a project, derived from marker files in its root.
/// Drives the fallback project icon and informs dev-server command detection.
nonisolated enum ProjectType: String, CaseIterable, Sendable {
    case xcode
    case nextjs
    case react
    case vue
    case nuxt
    case astro
    case sveltekit
    case angular
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
        case .react: return "atom"
        case .vue: return "triangle.fill"
        case .nuxt: return "mountain.2.fill"
        case .astro: return "moon.stars"
        case .sveltekit: return "bolt.fill"
        case .angular: return "shield.fill"
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
        case .react: return "React"
        case .vue: return "Vue"
        case .nuxt: return "Nuxt"
        case .astro: return "Astro"
        case .sveltekit: return "SvelteKit"
        case .angular: return "Angular"
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
        // JS frameworks with a unique config file. Nuxt is checked before Vue
        // (a Nuxt project also depends on `vue`); Astro is its own type rather
        // than a generic static site.
        if existsAny(["nuxt.config.js", "nuxt.config.ts", "nuxt.config.mjs"]) {
            return .nuxt
        }
        if existsAny(["astro.config.mjs", "astro.config.js", "astro.config.ts", "astro.config.mts"]) {
            return .astro
        }
        if existsAny(["svelte.config.js", "svelte.config.mjs"]) {
            return .sveltekit
        }
        if exists("angular.json") {
            return .angular
        }
        // Static-site generators (Jekyll, MkDocs) are specific enough to win
        // over a bare package.json; a plain `index.html` is only a last resort.
        if existsAny(["_config.yml", "mkdocs.yml"]) {
            return .staticSite
        }
        // Vue and React have no guaranteed marker file — they are identified by
        // a dependency in package.json. Meta-frameworks are matched first so a
        // project isn't mislabeled as the framework it is built on.
        if exists("package.json") {
            let dependencies = packageJSONDependencies(at: url, fileManager: fileManager)
            if dependencies.contains("astro") { return .astro }
            if dependencies.contains("nuxt") { return .nuxt }
            if dependencies.contains("next") { return .nextjs }
            if dependencies.contains("@angular/core") { return .angular }
            if dependencies.contains("@sveltejs/kit") { return .sveltekit }
            if dependencies.contains("vue") { return .vue }
            if dependencies.contains("react") { return .react }
            return .node
        }
        if exists("index.html") {
            return .staticSite
        }
        return .unknown
    }

    /// The merged `dependencies` + `devDependencies` package names from a
    /// `package.json` in the project root. Empty when the file is absent or
    /// malformed — callers treat that as "no framework dependency found".
    private static func packageJSONDependencies(
        at url: URL,
        fileManager: FileManager
    ) -> Set<String> {
        let packageURL = url.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path),
              let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else {
            return []
        }
        var names: Set<String> = []
        for key in ["dependencies", "devDependencies"] {
            if let group = json[key] as? [String: Any] {
                names.formUnion(group.keys)
            }
        }
        return names
    }
}
