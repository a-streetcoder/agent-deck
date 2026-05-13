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
        let error: String?
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
        .init(provider: "openai", model: "gpt-5.5")
    ]

    private let evalThinkingLevels = [
        "off",
        "minimal",
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
    private let exactEvalRuns: [EvalRunConfig]? = nil

    private let enabledAgents: Set<String> = [
        "scout",
        "planner",
        "worker",
        "reviewer"
    ]

    private let enabledTaskIDs: Set<String>? = nil

    private let runTimeoutSeconds: TimeInterval = 10 * 60

    private var evalTasks: [EvalTask] {
        [
            EvalTask(
                id: "scout-native-subagent-model-flow",
                agent: "scout",
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
                id: "scout-append-system-prompt-flow",
                agent: "scout",
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
                id: "planner-real-rpc-eval-harness",
                agent: "planner",
                prompt: """
                Plan an implementation for an opt-in real RPC evaluation test for bundled native subagents.
                It must run this repo as the project, test configurable models and thinking levels
                off/minimal/low/medium/high, save artifacts, and score report-only outputs.
                Do not edit files. Do not run formatting, tests, or git commands.
                Return a concrete implementation plan with files, steps, risks, and validation.
                """,
                expectedFacts: [
                    "agent-deckTests",
                    "PiSubagentRunService",
                    "PiAgentSessionStore",
                    "AGENT_DECK_REAL_RPC_EVAL",
                    "AGENT_DECK_PI_PATH",
                    "bundled-agents",
                    "summary.json",
                    "score.json"
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
                id: "worker-report-only-subagent-eval-patch",
                agent: "worker",
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
                id: "worker-report-only-model-fallback",
                agent: "worker",
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
                id: "reviewer-runtime-validation-coverage",
                agent: "reviewer",
                prompt: """
                Review the current native subagent runtime validation coverage.
                Look for meaningful gaps around real RPC behavior, model/thinking inheritance,
                artifact persistence, fork context, and no-edit report-only safety.
                Do not edit files. Do not run formatting, tests, or git commands.
                Return findings first with file/test evidence.
                """,
                expectedFacts: [
                    "PiSubagentRuntimeSmokeTests",
                    "PiAgentBridgeSmokeTests",
                    "PiTestSupport",
                    "fake Pi executable",
                    "real RPC",
                    "model/thinking",
                    "fork"
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
        setenv("AGENT_DECK_REAL_RPC_EVAL", "1", 1)
        setenv("AGENT_DECK_PI_PATH", "/opt/homebrew/bin/pi", 1)

        guard ProcessInfo.processInfo.environment["AGENT_DECK_REAL_RPC_EVAL"] == "1" else {
            throw XCTSkip("Set AGENT_DECK_REAL_RPC_EVAL=1 to run real Pi RPC native subagent evals.")
        }
        guard ProcessInfo.processInfo.environment["AGENT_DECK_PI_PATH"]?.isEmpty == false else {
            throw XCTSkip("Set AGENT_DECK_PI_PATH to the real pi executable before running real RPC evals.")
        }

        let projectURL = repoRootURL()
        let outputRoot = try makeOutputRoot()
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
        let runConfigs = expandedRunConfigs()
        for task in tasks {
            let baseAgent = try XCTUnwrap(agentsByName[task.agent], "Missing bundled/effective agent named \(task.agent)")
            for runConfig in runConfigs {
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
                    runDirectory: runDirectory
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
        runDirectory: URL
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
        try writeJSON(finalRun, to: runDirectory.appendingPathComponent("run.json"))
        try writeJSON(score, to: runDirectory.appendingPathComponent("score.json"))

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
        if base.name == "worker", let tools = config.tools {
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

    private func writeSummaryMarkdown(_ summaries: [EvalRunSummary], to url: URL) throws {
        var lines = [
            "# Native Bundled Subagent Real RPC Eval",
            "",
            "| Agent | Model | Thinking | Task | Status | Score | Missing Facts |",
            "|---|---|---|---|---|---:|---|"
        ]
        for summary in summaries.sorted(by: summarySort) {
            let model = [summary.provider, summary.model].compactMap { $0 }.joined(separator: "/")
            let missing = summary.missingFacts.isEmpty ? "" : summary.missingFacts.joined(separator: ", ")
            lines.append("| \(summary.agent) | \(model) | \(summary.thinking) | \(summary.taskID) | \(summary.status) | \(summary.score) | \(missing) |")
        }
        lines.append("")
        lines.append("Scores are automatic first-pass fact matching from 1-5. Manually review each `output.md` for accuracy, hallucinations, and usefulness.")
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
