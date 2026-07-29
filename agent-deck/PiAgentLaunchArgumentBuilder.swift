import Foundation

/// Pure helpers for building the `pi --mode rpc` argument lists that depend on
/// an `EffectiveAgentRecord` — `--system-prompt` / `--append-system-prompt`,
/// `--tools` / `--no-tools`, and `--extension` for agent-defined extensions.
///
/// These were originally private methods on `PiSubagentRunService`. They are
/// hoisted here so both the subagent runner and the new 1:1 agent-chat branch
/// inside `PiAgentRunnerService` can share a single implementation.
///
/// `buildSystemPrompt` / `nativeBoundaryPrompt` deliberately stay inside
/// `PiSubagentRunService` — those embed delegated-child boundary text that
/// makes no sense in agent-chat mode (the human is the supervisor, there is
/// no parent agent).
enum PiAgentLaunchArgumentBuilder {
    /// Inputs for `toolArguments` / `resolvedTools`. The flag bag mirrors what
    /// `PiSubagentRunService.toolArguments(...)` historically accepted.
    struct ToolProfile {
        let agent: EffectiveAgentRecord
        /// `false` in agent-chat mode — V1 strips `contact_supervisor` because
        /// there is no parent to receive the request.
        let includeSupervisorTool: Bool
        let includeMemoryTools: Bool
        let includeExaTools: Bool
        let includeFallbackWebFetchTool: Bool
        /// Whether the native `mcp` proxy tool was injected for this agent. When the
        /// agent declares a restrictive `tools:` allowlist, `mcp` must be added to it
        /// (like the memory tools) or Pi blocks the bridge-registered tool.
        var includeMCPTool: Bool = false
    }

    /// Build the `--system-prompt` / `--append-system-prompt` pair for the agent
    /// based on its `systemPromptMode` (defaults to `replace`).
    static func systemPromptArguments(for agent: EffectiveAgentRecord, prompt: String) -> [String] {
        let mode = agent.resolved.systemPromptMode ?? "replace"
        if mode == "append" {
            return ["--append-system-prompt", prompt]
        }
        return ["--system-prompt", prompt, "--append-system-prompt", ""]
    }

    /// Build the `--tools` (or `--no-tools`) argument list from the agent's
    /// allowlist, filtered by the provided capability flags. Returns an empty
    /// array when the agent declares no `tools` field, signalling "no
    /// restriction" — the caller leaves Pi's defaults in place.
    static func toolArguments(_ profile: ToolProfile) -> [String] {
        guard let tools = profile.agent.resolved.tools else { return [] }
        let supportedTools = resolvedTools(from: tools, profile: profile)
        guard !supportedTools.isEmpty else { return ["--no-tools"] }
        return ["--tools", supportedTools.joined(separator: ",")]
    }

    /// Convenience for callers that want the resolved tool list (for display
    /// or audit purposes) using the same filter rules as `toolArguments`.
    static func resolvedTools(_ profile: ToolProfile) -> [String] {
        resolvedTools(from: profile.agent.resolved.tools ?? [], profile: profile)
    }

    /// Build the `--extension` flag pairs for the agent's authored extensions.
    /// When `prependNoExtensions` is `true` (the subagent default) the result
    /// starts with a `--no-extensions` so the agent-defined list is the only
    /// thing loaded. The agent-chat runner shares the user-extension list with
    /// regular Pi sessions and emits its own `--no-extensions` upfront, so it
    /// passes `false` here to avoid clobbering its preceding `--extension`
    /// arguments.
    static func agentExtensionArguments(for agent: EffectiveAgentRecord, prependNoExtensions: Bool = true) -> [String] {
        var args: [String] = []
        if prependNoExtensions {
            args.append("--no-extensions")
        }
        for ext in agent.resolved.extensions ?? [] where !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--extension", ext])
        }
        return args
    }

    // MARK: - User Pi extension loading

    /// The leading `--no-extensions` flag for a launch. Both extension-loading modes
    /// disable Pi's ambient discovery; Agent Deck always builds the explicit list itself.
    /// Emit this BEFORE any `--extension` arguments.
    static func noExtensionsArgument(settings: AppSettings) -> [String] {
        settings.piAgentExtensionLoadingMode.ambientPiExtensionArguments
    }

    /// `--no-extensions` plus package model-provider extensions.
    ///
    /// Pi Deck always disables ambient extension discovery. That also drops
    /// `settings.json` packages such as `npm:pi-grok-cli`, which register providers
    /// like `grok-cli`. Without re-injecting those package entrypoints, launches fail with
    /// `Unknown provider "grok-cli"` even though `pi --list-models` (ambient on) lists them.
    static func isolatedLaunchBaseArguments(
        settings: AppSettings,
        projectURL: URL? = nil,
        discoveryService: PiExtensionDiscoveryService = PiExtensionDiscoveryService()
    ) -> [String] {
        noExtensionsArgument(settings: settings)
            + packageExtensionArguments(settings: settings, projectURL: projectURL, discoveryService: discoveryService)
    }

    /// Early `--extension` paths for enabled **model/auth provider** packages only
    /// (e.g. `pi-grok-cli`). Emit after `--no-extensions` and **before** Deck bridges so
    /// providers exist when the model is selected.
    ///
    /// Non-provider packages (tools/UI) are **not** loaded here — they either conflict with
    /// Deck bridges (`pi-ask-user` vs `ask_user`) or belong after bridges via
    /// `userSelectedExtensionArguments` when mode is `.useMyExtensions`.
    static func packageExtensionArguments(
        settings: AppSettings,
        projectURL: URL?,
        discoveryService: PiExtensionDiscoveryService = PiExtensionDiscoveryService()
    ) -> [String] {
        var args: [String] = []
        var seen = Set<String>()
        for candidate in discoveryService.enabledCandidates(settings: settings, projectRoot: projectURL)
            where candidate.discoveryKind == .package
        {
            guard isModelProviderPackage(candidate) else { continue }
            let source = candidate.launchSource
            guard seen.insert(source).inserted else { continue }
            args.append(contentsOf: ["--extension", source])
        }
        return args
    }

    /// Trailing user-opted extensions for `.useMyExtensions`:
    /// 1. non-provider packages (tool/UI packages the user enabled),
    /// 2. then path/file extensions under `~/.pi/agent/extensions`.
    ///
    /// Packages that Deck already supersedes (`pi-ask-user`, web bridges, …) are skipped so
    /// Pi does not fail the whole launch with "Tool X conflicts with …".
    /// Emit **after** all Agent Deck bridge `--extension`s (first-registration-wins).
    static func userSelectedExtensionArguments(
        settings: AppSettings,
        projectURL: URL?,
        discoveryService: PiExtensionDiscoveryService = PiExtensionDiscoveryService()
    ) -> [String] {
        guard settings.piAgentExtensionLoadingMode.usesCustomPiExtensionSelection else { return [] }
        var args: [String] = []
        var seen = Set<String>()
        for candidate in discoveryService.enabledCandidates(settings: settings, projectRoot: projectURL) {
            if candidate.discoveryKind == .package {
                // Model providers already injected early; Deck-owned tools must not reload.
                if isModelProviderPackage(candidate) { continue }
                if isDeckSupersededPackage(candidate) { continue }
            }
            let source = candidate.launchSource
            guard seen.insert(source).inserted else { continue }
            args.append(contentsOf: ["--extension", source])
        }
        return args
    }

    /// Packages that register chat model providers (not tools/UI).
    /// Keep this conservative so managed mode does not pull in pi-subagents / MCP / etc.
    static func isModelProviderPackage(_ candidate: PiExtensionCandidate) -> Bool {
        let baseName = packageBaseName(candidate)
        guard !baseName.isEmpty else { return false }
        let knownBaseNames: Set<String> = [
            "pi-grok-cli",
            "pi-xai-oauth",
        ]
        if knownBaseNames.contains(baseName) { return true }
        // Heuristic for future oauth/model provider packages.
        if baseName.contains("oauth") { return true }
        if baseName.contains("grok") && !baseName.contains("web") { return true }
        return false
    }

    /// Packages whose tools Deck already injects as first-party bridges.
    /// Loading them (before or after) causes hard launch failures: tool name conflicts.
    static func isDeckSupersededPackage(_ candidate: PiExtensionCandidate) -> Bool {
        let baseName = packageBaseName(candidate)
        guard !baseName.isEmpty else { return false }
        let knownBaseNames: Set<String> = [
            "pi-ask-user",
            "pi-web-access",
        ]
        if knownBaseNames.contains(baseName) { return true }
        // Scoped npm names like `rpiv-ask-user-question` still register ask_* tools.
        if baseName.contains("ask-user") { return true }
        return false
    }

    /// Lowercased last path segment of `packageName` (`@scope/name` → `name`).
    private static func packageBaseName(_ candidate: PiExtensionCandidate) -> String {
        let name = (candidate.packageName ?? "").lowercased()
        guard !name.isEmpty else { return "" }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    // MARK: - Internal

    private static func resolvedTools(from tools: [String], profile: ToolProfile) -> [String] {
        var result = tools.filter { tool in
            let normalized = tool.lowercased()
            if normalized == PiNativeSubagentBridgeExtensions.childSupervisorToolName { return profile.includeSupervisorTool }
            if PiNativeSubagentBridgeExtensions.exaToolNames.contains(normalized) { return profile.includeExaTools }
            if normalized == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName { return profile.includeFallbackWebFetchTool }
            return true
        }
        if profile.includeMemoryTools {
            result.append(contentsOf: PiNativeSubagentBridgeExtensions.memoryToolNames)
        }
        if profile.includeMCPTool {
            result.append(PiNativeSubagentBridgeExtensions.mcpProxyToolName)
        }
        return distinctPreservingOrder(result)
    }

    private static func distinctPreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }
}
