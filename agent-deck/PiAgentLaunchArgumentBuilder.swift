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

    /// Build the ambient Pi extension-discovery arguments from Agent Deck's
    /// settings. In custom-selection mode this emits `--no-extensions` plus
    /// explicit `--extension` pairs for every checked candidate.
    static func ambientExtensionArguments(
        settings: AppSettings,
        projectURL: URL?,
        discoveryService: PiExtensionDiscoveryService = PiExtensionDiscoveryService()
    ) -> [String] {
        var args = settings.piAgentExtensionLoadingMode.ambientPiExtensionArguments
        guard settings.piAgentExtensionLoadingMode.usesCustomPiExtensionSelection else { return args }

        let candidates = discoveryService.enabledCandidates(settings: settings, projectRoot: projectURL)
        for candidate in candidates {
            args.append(contentsOf: ["--extension", candidate.launchSource])
        }
        return args
    }

    /// Build the `--extension` flag pairs for the agent's authored extensions.
    /// When `prependNoExtensions` is `true` (the managed-extension default) the
    /// result starts with a `--no-extensions` so the agent-defined list is the
    /// only non-Agent-Deck extension set loaded. Callers pass `false` when a
    /// surrounding launch preference already controls ambient extension
    /// discovery or when preserving normal Pi extension discovery.
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

    // MARK: - Internal

    private static func resolvedTools(from tools: [String], profile: ToolProfile) -> [String] {
        var result = tools.filter { tool in
            let normalized = tool.lowercased()
            if normalized == "contact_supervisor" { return profile.includeSupervisorTool }
            if PiNativeSubagentBridgeExtensions.exaToolNames.contains(normalized) { return profile.includeExaTools }
            if normalized == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName { return profile.includeFallbackWebFetchTool }
            return true
        }
        if profile.includeMemoryTools {
            result.append(contentsOf: PiNativeSubagentBridgeExtensions.memoryToolNames)
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
