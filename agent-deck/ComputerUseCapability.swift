import Foundation

/// Agent Deck's explicitly-supported Computer Use adapter. This is deliberately
/// narrower than generic plugin importing: Codex's bundled skill uses `node_repl`,
/// which Pi does not provide, so it must never be passed to Pi as a skill.
nonisolated enum ComputerUseCapability {
    static let pluginID = CodexPluginMCPDiscovery.computerUsePluginID
    static let serverName = CodexComputerUseMCPIntegration.serverName

    /// These are runtime instructions rather than a `--skill` file. That keeps the
    /// guide Agent Deck-owned, re-materialized on every launch, and usable by
    /// restrictive agents without granting Pi's filesystem `read` tool.
    static let guide = """
    Computer Use (observation-only):
    - Call the proxy as `mcp({ tool: \"codex-computer-use/list_apps\", args: {} })`.
    - Only tools currently catalogued and allowed by Agent Deck may be used. At this observation-only phase, do not assume `get_app_state` or action tools are available.
    - Prefer element IDs when later catalogued tools support them. Obtain fresh state before and after every action once action tools exist.
    - Ask for explicit confirmation before any risky external effect.
    """

    static func isComputerUsePluginSkill(_ reference: CodexPluginSkillReference) -> Bool {
        reference.marketplace == "openai-bundled" && reference.plugin == "computer-use"
    }

    /// Resolve only the stored, recognized legacy references before they are
    /// removed. These names are used solely to skip now-missing legacy entries
    /// during this process; a same-named user skill still resolves normally.
    static func legacySkillNames(for references: Set<CodexPluginSkillReference>) -> Set<String> {
        let legacyReferences = references.filter(isComputerUsePluginSkill)
        guard !legacyReferences.isEmpty else { return [] }
        // `computer-use` is the bundled skill's stable frontmatter name. Reading
        // the installed file additionally covers an active version that reports
        // a different name; neither name is ignored when a user skill resolves.
        return Set(["computer-use"] + legacyReferences.compactMap { reference in
            CodexPluginSkillDiscovery.resolve(reference).flatMap { ExternalSkillDiscovery.candidate(at: $0)?.name }
        })
    }

    /// Returns true only for the installed raw skill inside the verified bundled
    /// plugin. Canonical paths and the selected package manifest identity prevent
    /// a user-authored or copied `computer-use` folder from being blocked.
    static func isInstalledRawSkill(at path: URL, packages: [CodexPluginSkillDiscovery.Package] = CodexPluginSkillDiscovery.activePackages()) -> Bool {
        let candidateRoot = canonical(path)
        guard let candidate = ExternalSkillDiscovery.candidate(at: candidateRoot), candidate.name == "computer-use" else { return false }
        return packages.contains { package in
            package.identity.marketplace == "openai-bundled"
                && package.identity.plugin == "computer-use"
                && isContained(candidateRoot, in: canonical(package.skillsRoot))
        }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ child: URL, in root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path + "/")
    }

    /// The guide follows the same scope as the MCP proxy, but is only added for
    /// the discovered plugin entry. A user-configured same-name server is a collision,
    /// not this capability, and must never receive this guide.
    static func hasActiveAssignment(
        scope: Set<String>,
        entries: [MCPServerEntry],
        catalogEntries: [MCPCatalogEntry]
    ) -> Bool {
        guard scope.contains(serverName),
              catalogEntries.contains(where: { $0.server == serverName && $0.tool == "list_apps" }),
              let entry = entries.first(where: { $0.name == serverName }) else { return false }
        guard entry.isAvailable, entry.toolPolicy == .computerUseObservationOnly else { return false }
        if case .codexPlugin = entry.provenance { return true }
        return false
    }

    static func appendGuide(
        to catalog: String?,
        scope: Set<String>,
        entries: [MCPServerEntry],
        catalogEntries: [MCPCatalogEntry]
    ) -> String? {
        guard hasActiveAssignment(scope: scope, entries: entries, catalogEntries: catalogEntries) else { return catalog }
        let parts = [catalog?.trimmingCharacters(in: .whitespacesAndNewlines), guide]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.joined(separator: "\n\n")
    }
}
