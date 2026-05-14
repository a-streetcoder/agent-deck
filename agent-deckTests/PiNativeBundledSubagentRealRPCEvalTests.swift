import XCTest
@testable import agent_deck

@MainActor
final class PiNativeBundledSubagentRealRPCEvalTests: XCTestCase {
    private struct EvalModelConfig: Codable, Hashable {
        let provider: String?
        let model: String

        var pathComponent: String {
            "\(provider ?? "default")_\(model)"
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
        }
    }

    private struct EvalRunConfig: Codable, Hashable {
        let provider: String?
        let model: String
        let thinking: String
        let agents: Set<String>?

        init(provider: String?, model: String, thinking: String, agents: Set<String>? = nil) {
            self.provider = provider
            self.model = model
            self.thinking = thinking
            self.agents = agents
        }

        var modelConfig: EvalModelConfig {
            EvalModelConfig(provider: provider, model: model)
        }
    }

    private struct EvalTask: Codable, Hashable {
        let id: String
        let agent: String
        let prompt: String
        let expectedFacts: [String]
    }

    private struct EvalScore: Codable, Hashable {
        let score: Int
        let matchedFacts: [String]
        let missingFacts: [String]
        let notes: String
    }

    private struct EvalRunSummary: Codable, Hashable {
        let agent: String
        let provider: String?
        let model: String
        let thinking: String
        let taskID: String
        let status: String
        let score: Int
        let matchedFacts: [String]
        let missingFacts: [String]
        let outputPath: String
        let artifactDirectory: String
        let durationMs: Int?
        let tokenUsage: EvalTokenUsage
        let error: String?
    }

    private struct EvalTokenUsage: Codable, Hashable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let totalTokens: Int?
        let costUSD: Double?
        let costSource: String?
        let pricing: EvalModelPricing?

        var markdownSummary: String {
            [
                inputTokens.map { "in: \($0)" },
                outputTokens.map { "out: \($0)" },
                cacheReadTokens.map { "cache read: \($0)" },
                cacheWriteTokens.map { "cache write: \($0)" },
                totalTokens.map { "total: \($0)" },
                costUSD.map { String(format: "cost: $%.6f", $0) }
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        }
    }

    private struct EvalModelPricing: Codable, Hashable {
        let provider: String
        let model: String
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double
        let cacheWritePerMillion: Double
    }

    private struct PiModelPricingRow: Decodable {
        let provider: String
        let model: String
        let cost: Cost

        struct Cost: Decodable {
            let input: Double
            let output: Double
            let cacheRead: Double
            let cacheWrite: Double
        }
    }

    private struct EvalManifest: Codable, Hashable {
        let projectPath: String
        let createdAt: Date
        let models: [EvalModelConfig]
        let thinkingLevels: [String]
        let exactRuns: [EvalRunConfig]?
        let tasks: [EvalTask]
        let outputDirectory: String
        let timeoutSeconds: TimeInterval
    }

    // Edit these constants when you want to change eval coverage.
    private let evalModels: [EvalModelConfig] = [
        .init(provider: "openai-codex", model: "gpt-5.4"),
        .init(provider: "openai-codex", model: "gpt-5.5")
    ]

    private let evalThinkingLevels = [
        "off",
        "low",
        "medium",
        "high"
    ]

    // Set this to run only exact model/thinking combinations instead of the
    // evalModels x evalThinkingLevels cross-product.
    //
    // Examples:
    // private let exactEvalRuns: [EvalRunConfig]? = [
    //     .init(provider: "opencode", model: "deepseek", thinking: "high"),
    //     .init(provider: "openai", model: "gpt-5.4", thinking: "low")
    // ]
    private let exactEvalRuns: [EvalRunConfig]? = [
        .init(provider: "openai-codex", model: "gpt-5.4", thinking: "off"),
        .init(provider: "openai-codex", model: "gpt-5.4", thinking: "low"),
        .init(provider: "openai-codex", model: "gpt-5.4", thinking: "medium"),
        .init(provider: "openai-codex", model: "gpt-5.4", thinking: "high"),
        .init(provider: "openai-codex", model: "gpt-5.5", thinking: "off"),
        .init(provider: "openai-codex", model: "gpt-5.5", thinking: "low"),
        .init(provider: "openai-codex", model: "gpt-5.5", thinking: "medium"),
        .init(provider: "openai-codex", model: "gpt-5.5", thinking: "high"),
        .init(provider: "openai-codex", model: "gpt-5.4-mini", thinking: "medium", agents: ["explorer", "reviewer"]),
        .init(provider: "openai-codex", model: "gpt-5.4-mini", thinking: "high", agents: ["explorer", "reviewer"]),
        .init(provider: "openai-codex", model: "gpt-5.4-mini", thinking: "xhigh", agents: ["explorer", "reviewer"])
    ]

    private let enabledAgents: Set<String> = [
        "explorer",
        "planner",
        "reviewer"
    ]

    private let enabledTaskIDs: Set<String>? = [
        "explorer-native-subagent-model-flow",
        "planner-appkit-chat-performance-port",
        "reviewer-agent-rename-commit"
    ]

    private let runTimeoutSeconds: TimeInterval = 10 * 60

    private var evalTasks: [EvalTask] {
        [
            EvalTask(
                id: "explorer-native-subagent-model-flow",
                agent: "explorer",
                prompt: """
                Recon the native subagent model/thinking resolution path in this repo.
                Find the relevant files and symbols for how a child subagent chooses provider, model,
                and thinking level, and how that becomes Pi RPC launch arguments.
                Do not edit files. Do not run formatting, tests, or git commands.
                Return concise evidence-backed context only.
                """,
                expectedFacts: [
                    "PiSubagentLaunchPlanner",
                    "modelSelection",
                    "PiRPCClient.launchArguments",
                    "PiSubagentRunService",
                    "--provider",
                    "--model",
                    "thinking"
                ]
            ),
            EvalTask(
                id: "explorer-append-system-prompt-flow",
                agent: "explorer",
                prompt: """
                Recon how parent Pi RPC sessions handle system prompt and append-system-prompt arguments.
                Identify where native subagent catalog prompt injection happens and how APPEND_SYSTEM.md
                preservation is represented in the current code/docs.
                Do not edit files. Do not run formatting, tests, or git commands.
                """,
                expectedFacts: [
                    "PiAgentRunnerService",
                    "--append-system-prompt",
                    "nativeSubagentCatalogProvider",
                    "APPEND_SYSTEM.md",
                    "agent-deck-documentation/pi-rpc-launch-flags.md"
                ]
            ),
            EvalTask(
                id: "planner-appkit-chat-performance-port",
                agent: "planner",
                prompt: """
                Plan a production-grade performance rewrite of Agent Deck's Pi Agent chat UI.

                Context: The current SwiftUI chat in Pi Agent view feels slow and can render blank chats until
                the user scrolls. Prior attempts included SwiftUI optimization, profiler investigation, and
                LazyVStack, but the issue remains. The goal is to preserve all UI/UX and functionality while
                improving rendering and streaming performance.

                Requirements:
                1. Inspect the current chat UI and list all user-visible and functional capabilities it has.
                2. Plan an AppKit solution that is 1:1 equivalent in rendering, information density, look and feel,
                   row behavior, selection/copy affordances, native subagent cards, thinking/tool rendering, and
                   auto-scrolling while Pi streams content.
                3. Plan how to use web research and Apple documentation for the AppKit design choices. If Apple
                   documentation is needed, use/read the local skill at:
                   /Users/andrea/.pi/agent/skills/apple-documentation/SKILL.md
                4. Include a measurement strategy using profiler sessions. If useful, reference the local skill at
                   /Users/andrea/Documents/GitHub/skill-sources/agent-scripts/skills/native-app-performance.
                5. Compare two implementation branches:
                   - app-kit: full AppKit port of the chat UI, and session list too if profiling justifies it.
                   - app-kit-hybrid: mixed AppKit/SwiftUI approach for rows or host views.
                6. Define validation to prove no UI, UX, information, behavior, or accessibility regressions.
                7. Define a final report structure comparing real performance differences and tradeoffs.

                Do not edit files. Do not run formatting, tests, or git commands. Return a concrete implementation
                plan with files to inspect, architecture options, profiling steps, risks, acceptance criteria, and
                report outline.
                """,
                expectedFacts: [
                    "PiAgentViews",
                    "PiAgentTranscriptViews",
                    "PiAgentSubagentViews",
                    "PiAgentActivityPanelViews",
                    "AppKit",
                    "apple-documentation",
                    "NSScrollView",
                    "NSTableView",
                    "auto-scroll",
                    "Instruments",
                    "app-kit",
                    "app-kit-hybrid"
                ]
            ),
            EvalTask(
                id: "planner-cli-transcript-sync",
                agent: "planner",
                prompt: """
                Plan how to add or validate syncing Pi Agent transcripts when the underlying Pi JSONL
                session file is updated externally by the CLI. Use current repo structure.
                Do not edit files. Do not run formatting, tests, or git commands.
                Return a concise plan with affected files, edge cases, and tests.
                """,
                expectedFacts: [
                    "PiAgentSessionStore",
                    "PiAgentSessionRecord.piSessionFile",
                    "transcriptsBySessionID",
                    "PiRPCClient",
                    "session JSONL",
                    "external CLI"
                ]
            ),
            EvalTask(
                id: "coder-report-only-subagent-eval-patch",
                agent: "coder",
                prompt: """
                Report-only implementation task. Do not edit files. Do not run formatting, tests, or git commands.
                Work out the exact patch you would make to add an opt-in real RPC eval test for bundled
                native subagents, with configurable models and thinking levels.
                Put all proposed code changes in your final response in a readable file-style format,
                using paths and fenced Swift snippets or pseudodiff. Agent Deck will save that final response
                to output.md for analysis; do not write project files yourself.
                """,
                expectedFacts: [
                    "PiNativeBundledSubagentRealRPCEvalTests",
                    "EvalModelConfig",
                    "EvalTask",
                    "off",
                    "minimal",
                    "low",
                    "medium",
                    "high",
                    "PiSubagentRunService",
                    "output.md"
                ]
            ),
            EvalTask(
                id: "coder-report-only-model-fallback",
                agent: "coder",
                prompt: """
                Report-only implementation task. Do not edit files. Do not run formatting, tests, or git commands.
                Inspect native subagent fallback model support and describe the minimal code change
                required to add ordered fallback retry behavior for child runs if it is not already present.
                Put all proposed code changes in your final response in a readable file-style format,
                using paths and fenced Swift snippets or pseudodiff. Agent Deck will save that final response
                to output.md for analysis; do not write project files yourself.
                """,
                expectedFacts: [
                    "fallbackModels",
                    "AgentConfig",
                    "PiSubagentRunService",
                    "PiSubagentLaunchPlanner",
                    "provider/model failure",
                    "retry",
                    "transcript",
                    "output.md"
                ]
            ),
            EvalTask(
                id: "reviewer-agent-rename-commit",
                agent: "reviewer",
                prompt: """
                Review commit 6820ba5 (Rename built-in subagents to explorer and coder) in this repository.
                Use read-only inspection only; git show/diff/log commands are allowed, but do not edit files,
                run formatting, or run tests. Focus on correctness, migration risk, stale references, and whether
                UI/tests/docs/runtime behavior consistently use the renamed native agents.
                Return findings first with concrete file/symbol/commit evidence. If there are no material issues,
                say so clearly and include the strongest validation evidence.
                """,
                expectedFacts: [
                    "6820ba5",
                    "explorer",
                    "coder",
                    "scout",
                    "worker",
                    "bundled-agents",
                    "PiNativeBundledSubagentRealRPCEvalTests"
                ]
            ),
            EvalTask(
                id: "reviewer-first-paint-transcript-risk",
                agent: "reviewer",
                prompt: """
                Review the Pi Agent transcript rendering path for risks related to blank first paint,
                thinking entries, and native subagent cards. Do not edit files.
                Do not run formatting, tests, or git commands.
                Return correctness or regression risks with evidence from current SwiftUI code.
                """,
                expectedFacts: [
                    "PiAgentViews",
                    "PiAgentTranscriptViews",
                    "PiAgentRPCEventRenderCache",
                    "thinking",
                    "native subagent card",
                    "ScrollView",
                    "Lazy"
                ]
            )
        ]
    }

    func testBundledNativeSubagentsAcrossModelsAndThinkingLevelsUsingRealRPC() throws {
        guard ProcessInfo.processInfo.environment["AGENT_DECK_REAL_RPC_EVAL"] == "1" else {
            throw XCTSkip("Set AGENT_DECK_REAL_RPC_EVAL=1 to run real Pi RPC native subagent evals.")
        }
        guard ProcessInfo.processInfo.environment["AGENT_DECK_PI_PATH"]?.isEmpty == false else {
            throw XCTSkip("Set AGENT_DECK_PI_PATH to the real pi executable before running real RPC evals.")
        }

        let projectURL = repoRootURL()
        let outputRoot = try makeOutputRoot()
        let runConfigs = expandedRunConfigs()
        let pricingByModel = try loadModelPricing(runConfigs: runConfigs)
        try writeJSON(Array(pricingByModel.values).sorted { $0.provider + $0.model < $1.provider + $1.model }, to: outputRoot.appendingPathComponent("model-pricing.json"))
        let snapshot = PiScanner().scan(projectRoot: projectURL)
        let agentsByName = Dictionary(uniqueKeysWithValues: snapshot.builtinAgents.map { ($0.name, effectiveBuiltinAgent($0, projectRoot: projectURL.path)) })
        let tasks = evalTasks.filter { task in
            enabledAgents.contains(task.agent) && (enabledTaskIDs?.contains(task.id) ?? true)
        }
        let store = PiAgentSessionStore(fileURL: outputRoot.appendingPathComponent("agent-sessions.json"))
        let runner = PiSubagentRunService(store: store)
        let beforeStatus = gitStatus(in: projectURL)

        try writeJSON(
            EvalManifest(
                projectPath: projectURL.path,
                createdAt: Date(),
                models: evalModels,
                thinkingLevels: evalThinkingLevels,
                exactRuns: exactEvalRuns,
                tasks: tasks,
                outputDirectory: outputRoot.path,
                timeoutSeconds: runTimeoutSeconds
            ),
            to: outputRoot.appendingPathComponent("manifest.json")
        )

        var summaries: [EvalRunSummary] = []
        for task in tasks {
            let baseAgent = try XCTUnwrap(agentsByName[task.agent], "Missing bundled/effective agent named \(task.agent)")
            for runConfig in runConfigs where runConfig.agents?.contains(task.agent) ?? true {
                let model = runConfig.modelConfig
                let agent = evalAgent(from: baseAgent)
                let parent = try PiTestSupport.makeParentSession(
                    projectURL: projectURL,
                    model: runConfig.model,
                    provider: runConfig.provider,
                    thinking: runConfig.thinking
                )
                let runDirectory = outputRoot
                    .appendingPathComponent(task.agent, isDirectory: true)
                    .appendingPathComponent(model.pathComponent, isDirectory: true)
                    .appendingPathComponent(runConfig.thinking, isDirectory: true)
                    .appendingPathComponent(task.id, isDirectory: true)
                try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

                let summary = try runEval(
                    task: task,
                    agent: agent,
                    snapshot: snapshot,
                    parent: parent,
                    model: model,
                    thinking: runConfig.thinking,
                    runner: runner,
                    store: store,
                    runDirectory: runDirectory,
                    pricing: pricingByModel[pricingKey(provider: model.provider, model: model.model)]
                )
                summaries.append(summary)
            }
        }

        try writeJSON(summaries, to: outputRoot.appendingPathComponent("summary.json"))
        try writeSummaryMarkdown(summaries, to: outputRoot.appendingPathComponent("summary.md"))

        let afterStatus = gitStatus(in: projectURL)
        XCTAssertEqual(afterStatus, beforeStatus, "Real RPC eval changed the working tree. Inspect \(outputRoot.path) and the git diff before continuing.")
        XCTAssertFalse(summaries.isEmpty)
    }

    private func runEval(
        task: EvalTask,
        agent: EffectiveAgentRecord,
        snapshot: ScanSnapshot,
        parent: PiAgentSessionRecord,
        model: EvalModelConfig,
        thinking: String,
        runner: PiSubagentRunService,
        store: PiAgentSessionStore,
        runDirectory: URL,
        pricing: EvalModelPricing?
    ) throws -> EvalRunSummary {
        let run: PiSubagentRunRecord
        do {
            run = try runner.runSingle(
                parentSession: parent,
                agent: agent,
                snapshot: snapshot,
                task: task.prompt,
                useWorktreeIsolation: false,
                expectedOutcome: .reportOnly
            )
        } catch {
            let score = EvalScore(score: 1, matchedFacts: [], missingFacts: task.expectedFacts, notes: "Launch failed: \(error.localizedDescription)")
            try writeJSON(score, to: runDirectory.appendingPathComponent("score.json"))
            try writeText(error.localizedDescription, to: runDirectory.appendingPathComponent("error.txt"))
            return EvalRunSummary(
                agent: task.agent,
                provider: model.provider,
                model: model.model,
                thinking: thinking,
                taskID: task.id,
                status: "launch_failed",
                score: score.score,
                matchedFacts: score.matchedFacts,
                missingFacts: score.missingFacts,
                outputPath: "",
                artifactDirectory: "",
                durationMs: nil,
                tokenUsage: EvalTokenUsage(inputTokens: nil, outputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, totalTokens: nil, costUSD: nil, costSource: nil, pricing: pricing),
                error: error.localizedDescription
            )
        }

        let completed = PiTestSupport.waitUntil(timeout: runTimeoutSeconds) {
            guard let current = store.subagentRuns(for: parent.id).first(where: { $0.id == run.id }) else { return false }
            return !current.status.isActive
        }
        if !completed {
            runner.stop(runID: run.id, parentSessionID: parent.id)
        }

        let finalRun = store.subagentRuns(for: parent.id).first(where: { $0.id == run.id }) ?? run
        let artifactDirectory = URL(fileURLWithPath: finalRun.child?.artifactDirectory ?? finalRun.artifactDirectory)
        let outputURL = artifactDirectory.appendingPathComponent("output.md")
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? finalRun.summary ?? ""
        let score = scoreOutput(output, expectedFacts: task.expectedFacts, timedOut: !completed, status: finalRun.status)
        let transcript = store.subagentTranscript(for: run.id)

        try copyArtifactIfExists(artifactDirectory.appendingPathComponent("input.md"), to: runDirectory.appendingPathComponent("input.md"))
        try copyArtifactIfExists(artifactDirectory.appendingPathComponent("system-prompt.md"), to: runDirectory.appendingPathComponent("system-prompt.md"))
        try copyArtifactIfExists(outputURL, to: runDirectory.appendingPathComponent("output.md"))
        try writeJSON(transcript, to: runDirectory.appendingPathComponent("transcript.json"))
        let tokenUsage = tokenUsageFromSessionFile(finalRun.childPiSessionFile ?? finalRun.child?.sessionFile, fallbackRun: finalRun, pricing: pricing)

        try writeJSON(finalRun, to: runDirectory.appendingPathComponent("run.json"))
        try writeJSON(score, to: runDirectory.appendingPathComponent("score.json"))
        try writeJSON(tokenUsage, to: runDirectory.appendingPathComponent("token-usage.json"))

        return EvalRunSummary(
            agent: task.agent,
            provider: model.provider,
            model: model.model,
            thinking: thinking,
            taskID: task.id,
            status: completed ? finalRun.status.rawValue : "timed_out",
            score: score.score,
            matchedFacts: score.matchedFacts,
            missingFacts: score.missingFacts,
            outputPath: outputURL.path,
            artifactDirectory: artifactDirectory.path,
            durationMs: finalRun.durationMs,
            tokenUsage: tokenUsage,
            error: finalRun.error
        )
    }

    private func expandedRunConfigs() -> [EvalRunConfig] {
        if let exactEvalRuns {
            return exactEvalRuns
        }
        return evalModels.flatMap { model in
            evalThinkingLevels.map { thinking in
                EvalRunConfig(provider: model.provider, model: model.model, thinking: thinking)
            }
        }
    }

    private func effectiveBuiltinAgent(_ record: AgentRecord, projectRoot: String) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: record.id,
            name: record.name,
            projectRoot: projectRoot,
            builtin: record,
            globalCustom: nil,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: .builtin
        )
    }

    private func evalAgent(from base: EffectiveAgentRecord) -> EffectiveAgentRecord {
        var config = base.resolved
        // Keep provider/model/thinking inherited from the parent session so this
        // exercises the same default native subagent path the app uses.
        config.model = nil
        if base.name == "coder", let tools = config.tools {
            config.tools = tools.filter { tool in
                tool != "edit" && tool != "write"
            }
        }
        return EffectiveAgentRecord(
            id: "\(base.id):eval",
            name: base.name,
            projectRoot: base.projectRoot,
            builtin: base.builtin,
            globalCustom: nil,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: config,
            resolutionKind: base.resolutionKind
        )
    }

    private func scoreOutput(_ output: String, expectedFacts: [String], timedOut: Bool, status: PiSubagentRunStatus) -> EvalScore {
        guard !timedOut, status == .completed else {
            return EvalScore(score: 1, matchedFacts: [], missingFacts: expectedFacts, notes: "Run did not complete successfully: \(timedOut ? "timed out" : status.rawValue).")
        }
        let lowercasedOutput = output.lowercased()
        let matched = expectedFacts.filter { lowercasedOutput.contains($0.lowercased()) }
        let missing = expectedFacts.filter { !lowercasedOutput.contains($0.lowercased()) }
        let ratio = expectedFacts.isEmpty ? 1 : Double(matched.count) / Double(expectedFacts.count)
        let score: Int
        switch ratio {
        case 0.95...:
            score = 5
        case 0.75..<0.95:
            score = 4
        case 0.45..<0.75:
            score = 3
        case 0.20..<0.45:
            score = 2
        default:
            score = 1
        }
        let notes = "Matched \(matched.count)/\(expectedFacts.count) expected facts. Manual review should check accuracy, hallucinated files/types, and usefulness."
        return EvalScore(score: score, matchedFacts: matched, missingFacts: missing, notes: notes)
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeOutputRoot() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-native-subagent-evals", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func writeText(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyArtifactIfExists(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func loadModelPricing(runConfigs: [EvalRunConfig]) throws -> [String: EvalModelPricing] {
        let piPath = try XCTUnwrap(ProcessInfo.processInfo.environment["AGENT_DECK_PI_PATH"], "AGENT_DECK_PI_PATH is required to load Pi model pricing.")
        let packageRoot = piPackageRoot(from: URL(fileURLWithPath: piPath).resolvingSymlinksInPath())
        let authStorage = packageRoot.appendingPathComponent("dist/core/auth-storage.js").absoluteString
        let modelRegistry = packageRoot.appendingPathComponent("dist/core/model-registry.js").absoluteString
        let requested = Set(runConfigs.map { pricingKey(provider: $0.provider, model: $0.model) })
        let requestedJSON = String(data: try JSONEncoder().encode(Array(requested)), encoding: .utf8) ?? "[]"
        let script = """
        import { AuthStorage } from '\(authStorage)';
        import { ModelRegistry } from '\(modelRegistry)';
        const requested = new Set(\(requestedJSON));
        const registry = ModelRegistry.create(AuthStorage.create());
        const rows = registry.getAll()
          .filter((model) => requested.has(`${model.provider}/${model.id}`))
          .map((model) => ({ provider: model.provider, model: model.id, cost: model.cost }));
        console.log(JSON.stringify(rows));
        """
        let output = try runProcess(executable: "/usr/bin/env", arguments: ["node", "--input-type=module", "-e", script])
        let rows = try JSONDecoder().decode([PiModelPricingRow].self, from: Data(output.utf8))
        let pricing = Dictionary(uniqueKeysWithValues: rows.map { row in
            (pricingKey(provider: row.provider, model: row.model), EvalModelPricing(
                provider: row.provider,
                model: row.model,
                inputPerMillion: row.cost.input,
                outputPerMillion: row.cost.output,
                cacheReadPerMillion: row.cost.cacheRead,
                cacheWritePerMillion: row.cost.cacheWrite
            ))
        })
        let missing = requested.subtracting(pricing.keys)
        XCTAssertTrue(missing.isEmpty, "Missing Pi model pricing for: \(missing.sorted().joined(separator: ", "))")
        if !missing.isEmpty {
            throw NSError(domain: "PiNativeBundledSubagentRealRPCEvalTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing Pi model pricing for: \(missing.sorted().joined(separator: ", "))"])
        }
        return pricing
    }

    private func piPackageRoot(from resolvedPiURL: URL) -> URL {
        let parent = resolvedPiURL.deletingLastPathComponent()
        if parent.lastPathComponent == "dist" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "PiNativeBundledSubagentRealRPCEvalTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? out : err])
        }
        return out
    }

    private func tokenUsageFromSessionFile(_ sessionFile: String?, fallbackRun: PiSubagentRunRecord, pricing: EvalModelPricing?) -> EvalTokenUsage {
        let sessionUsage = sessionFile.flatMap { aggregateUsage(fromSessionFile: $0) }
        let input = sessionUsage?.inputTokens ?? fallbackRun.child?.inputTokens
        let output = sessionUsage?.outputTokens ?? fallbackRun.child?.outputTokens
        let cacheRead = sessionUsage?.cacheReadTokens
        let cacheWrite = sessionUsage?.cacheWriteTokens
        let total = sessionUsage?.totalTokens ?? fallbackRun.child?.totalTokens ?? [input, output, cacheRead, cacheWrite].compactMap { $0 }.reduce(0, +)
        let pricedCost = estimatedCost(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, pricing: pricing)
        return EvalTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: total,
            costUSD: sessionUsage?.costUSD ?? pricedCost,
            costSource: sessionUsage?.costUSD != nil ? "session_usage" : (pricedCost == nil ? nil : "pi_model_pricing"),
            pricing: pricing
        )
    }

    private func aggregateUsage(fromSessionFile path: String) -> EvalTokenUsage? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0
        var cost = 0.0
        var sawUsage = false
        var sawCost = false
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = usageObject(in: object) else { continue }
            sawUsage = true
            input += intValue(usage["input"])
            output += intValue(usage["output"])
            cacheRead += intValue(usage["cacheRead"])
            cacheWrite += intValue(usage["cacheWrite"])
            total += intValue(usage["totalTokens"]) + intValue(usage["total"])
            if let costObject = usage["cost"] as? [String: Any] {
                sawCost = true
                let explicitTotal = doubleValue(costObject["total"])
                cost += explicitTotal == 0
                    ? doubleValue(costObject["input"]) + doubleValue(costObject["output"]) + doubleValue(costObject["cacheRead"]) + doubleValue(costObject["cacheWrite"])
                    : explicitTotal
            }
        }
        guard sawUsage else { return nil }
        let computedTotal = total == 0 ? input + output + cacheRead + cacheWrite : total
        return EvalTokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: computedTotal,
            costUSD: sawCost ? cost : nil,
            costSource: sawCost ? "session_usage" : nil,
            pricing: nil
        )
    }

    private func usageObject(in object: [String: Any]) -> [String: Any]? {
        if let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" {
            return message["usage"] as? [String: Any]
        }
        if object["role"] as? String == "assistant" {
            return object["usage"] as? [String: Any]
        }
        return nil
    }

    private func estimatedCost(inputTokens: Int?, outputTokens: Int?, cacheReadTokens: Int?, cacheWriteTokens: Int?, pricing: EvalModelPricing?) -> Double? {
        guard let pricing else { return nil }
        return (Double(inputTokens ?? 0) * pricing.inputPerMillion
            + Double(outputTokens ?? 0) * pricing.outputPerMillion
            + Double(cacheReadTokens ?? 0) * pricing.cacheReadPerMillion
            + Double(cacheWriteTokens ?? 0) * pricing.cacheWritePerMillion) / 1_000_000
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    private func pricingKey(provider: String?, model: String) -> String {
        "\(provider ?? "default")/\(model)"
    }

    private func writeSummaryMarkdown(_ summaries: [EvalRunSummary], to url: URL) throws {
        var lines = [
            "# Native Bundled Subagent Real RPC Eval",
            "",
            "| Agent | Model | Thinking | Task | Status | Score | Tokens | Missing Facts |",
            "|---|---|---|---|---|---:|---|---|"
        ]
        for summary in summaries.sorted(by: summarySort) {
            let model = [summary.provider, summary.model].compactMap { $0 }.joined(separator: "/")
            let missing = summary.missingFacts.isEmpty ? "" : summary.missingFacts.joined(separator: ", ")
            let tokens = summary.tokenUsage.markdownSummary.isEmpty ? "unavailable" : summary.tokenUsage.markdownSummary
            lines.append("| \(summary.agent) | \(model) | \(summary.thinking) | \(summary.taskID) | \(summary.status) | \(summary.score) | \(tokens) | \(missing) |")
        }
        lines.append("")
        lines.append("Scores are automatic first-pass fact matching from 1-5. Manually review each `output.md` for accuracy, hallucinations, and usefulness. Token counts and per-run USD cost are recorded in `token-usage.json` and `summary.json`; model pricing captured from Pi's model registry is saved in `model-pricing.json`.")
        try writeText(lines.joined(separator: "\n"), to: url)
    }

    private func summarySort(_ lhs: EvalRunSummary, _ rhs: EvalRunSummary) -> Bool {
        if lhs.agent != rhs.agent { return lhs.agent < rhs.agent }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        if lhs.thinking != rhs.thinking { return lhs.thinking < rhs.thinking }
        return lhs.taskID < rhs.taskID
    }

    private func gitStatus(in projectURL: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--short"]
        process.currentDirectoryURL = projectURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "git status failed: \(error.localizedDescription)"
        }
    }
}
