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
    - Use `mcp({ tool: \"codex-computer-use/list_apps\", args: {} })` to identify an app, then call `get_app_state` with its returned app identifier.
    - `get_app_state` returns accessibility text and may include a screenshot. Prefer returned `element_index` identifiers when referring to elements.
    - Before any future action, obtain fresh app state; refresh it after changes. Only currently catalogued tools are callable—actions are blocked in this phase.
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
              ["list_apps", "get_app_state"].allSatisfy({ tool in catalogEntries.contains { $0.server == serverName && $0.tool == tool } }),
              let entry = entries.first(where: { $0.name == serverName }) else { return false }
        guard entry.isAvailable, entry.toolPolicy == .computerUseObservationOnly else { return false }
        if case .codexPlugin = entry.provenance { return true }
        return false
    }

    /// Converts known helper failures into safe, actionable guidance while retaining
    /// a bounded sanitized helper message for troubleshooting.
    static func runtimeDiagnostic(for helperError: String) -> String? {
        let normalized = helperError.lowercased()
        let guidance: String
        if normalized.contains("-1743") {
            guidance = "Computer Use needs macOS Automation permission (error -1743). In System Settings > Privacy & Security > Automation, allow the installed signed Computer Use service/Codex component—not Pi—then retry."
        } else if normalized.contains("accessibility") && (normalized.contains("denied") || normalized.contains("pending") || normalized.contains("permission") || normalized.contains("authorized")) {
            guidance = "Computer Use needs macOS Accessibility permission. In System Settings > Privacy & Security > Accessibility, allow the installed signed Computer Use service/Codex component—not Pi—then retry."
        } else if (normalized.contains("screen recording") || normalized.contains("screenrecording")) && (normalized.contains("denied") || normalized.contains("pending") || normalized.contains("permission") || normalized.contains("authorized")) {
            guidance = "Computer Use needs macOS Screen Recording permission. In System Settings > Privacy & Security > Screen Recording, allow the installed signed Computer Use service/Codex component—not Pi—then retry."
        } else if normalized.contains("cold start") || normalized.contains("service unavailable") || normalized.contains("service is unavailable") || normalized.contains("request timed out") || normalized.contains("timed out") {
            guidance = "Computer Use request timed out. The installed signed Computer Use service/Codex component may still be starting, unavailable, awaiting permission, or blocked. Wait briefly and retry; if it persists, check that component and macOS permissions (not Pi)."
        } else {
            return nil
        }
        return "\(guidance) Agent Deck will not request, reset, or change macOS permissions automatically. Original helper error: \(sanitizedDiagnostic(helperError))"
    }

    private static func sanitizedDiagnostic(_ value: String) -> String {
        let clipped = value.replacing(/\s+/, with: " ").prefix(500)
        return clipped.split(separator: " ").map { token in
            let text = String(token)
            let base64ish = text.count >= 32 && text.allSatisfy { $0.isLetter || $0.isNumber || "+/=_-".contains($0) }
            return base64ish ? "[redacted]" : text
        }.joined(separator: " ")
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
