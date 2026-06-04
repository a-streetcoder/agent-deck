import Foundation

@MainActor
final class SkillDescriptionGenerationService {
    enum GenerationError: LocalizedError {
        case emptyResponse
        case invalidResponse
        case timedOut
        case processExited(Int32)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Skill summary generation returned an empty response."
            case .invalidResponse: return "Skill summary generation returned an invalid response."
            case .timedOut: return "Skill summary generation timed out."
            case let .processExited(code): return "Skill summary generation process exited with code \(code)."
            case let .rpc(message): return message
            }
        }
    }

    private final class Run {
        let client: PiRPCClient
        let completion: (Result<String, Error>) -> Void
        var assistantText = ""
        var isFinished = false
        var timeoutTask: Task<Void, Never>?

        init(client: PiRPCClient, completion: @escaping (Result<String, Error>) -> Void) {
            self.client = client
            self.completion = completion
        }
    }

    private var runsByID: [UUID: Run] = [:]
    private let timeoutNanoseconds: UInt64 = 30_000_000_000

    func generate(
        skillContent: String,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String]
    ) async throws -> String {
        let userPrompt = Self.userPrompt(skillContent: skillContent)
        if FoundationModelAutomationService.isFoundationModel(model) {
            let response = try await FoundationModelAutomationService.generateOneShot(
                prompt: userPrompt,
                systemPrompt: Self.systemPrompt,
                temperature: 0.3,
                maxTokens: 220
            )
            return try Self.sanitizedSummary(response)
        }

        return try await withCheckedThrowingContinuation { continuation in
            startPiHelper(userPrompt: userPrompt, model: model, projectURL: projectURL, environment: environment) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func startPiHelper(
        userPrompt: String,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let runID = UUID()
        do {
            let client = try PiRPCClient(
                cwd: projectURL,
                provider: model.provider,
                modelArgument: PiSessionTitleGenerationService.runtimeModelArgument(modelID: model.model, thinkingLevel: "off"),
                extraArguments: [
                    "--no-session",
                ] + PiAgentLaunchArgumentBuilder.ambientExtensionArguments(settings: AppSettingsStore.shared.settings, projectURL: projectURL) + [
                    "--no-skills",
                    "--no-tools",
                    "--no-context-files",
                    "--no-prompt-templates",
                    "--no-themes",
                    "--system-prompt",
                    Self.systemPrompt,
                    "--append-system-prompt",
                    "",
                ],
                environment: environment,
                onEvent: { [weak self] events in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for event in events { self.handle(rawLine: event.rawLine, event: event.event, runID: runID) }
                    }
                },
                onStderr: { _ in },
                onTermination: { [weak self] exitCode in
                    Task { @MainActor [weak self] in self?.handleTermination(exitCode: exitCode, runID: runID) }
                }
            )
            let run = Run(client: client, completion: completion)
            runsByID[runID] = run
            let timeout = timeoutNanoseconds
            run.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.finish(runID: runID, result: .failure(GenerationError.timedOut)) }
            }
            client.prompt(userPrompt)
        } catch {
            completion(.failure(error))
        }
    }

    private func handle(rawLine: String, event: PiAgentRPCEvent?, runID: UUID) {
        guard let run = runsByID[runID], !run.isFinished, let event else { return }
        if event.type == "response", event.success == false {
            finish(runID: runID, result: .failure(GenerationError.rpc(event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine)))
            return
        }
        switch event.type {
        case "message_update":
            guard let assistantEvent = event.assistantMessageEvent,
                  (assistantEvent["type"]?.stringValue ?? "") == "text_delta" else { return }
            run.assistantText += assistantEvent["delta"]?.stringValue ?? ""
        case "message_end":
            guard let message = event.message,
                  (message["role"]?.stringValue ?? "assistant") == "assistant" else { return }
            let text = Self.extractAssistantText(from: message)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { run.assistantText = text }
        case "agent_end", "turn_end":
            do {
                finish(runID: runID, result: .success(try Self.sanitizedSummary(run.assistantText)))
            } catch {
                finish(runID: runID, result: .failure(error))
            }
        default:
            break
        }
    }

    private func handleTermination(exitCode: Int32, runID: UUID) {
        guard let run = runsByID[runID], !run.isFinished else { return }
        finish(runID: runID, result: .failure(GenerationError.processExited(exitCode)))
    }

    private func finish(runID: UUID, result: Result<String, Error>) {
        guard let run = runsByID.removeValue(forKey: runID), !run.isFinished else { return }
        run.isFinished = true
        run.timeoutTask?.cancel()
        run.client.stop()
        run.completion(result)
    }

    private static let systemPrompt = """
    You write a 2–3 sentence summary of a coding-agent skill, to help a developer decide whether it is worth importing.

    Read the entire SKILL.md (frontmatter + body) and explain in concrete terms: what the skill DOES (the verb), WHEN an agent should reach for it (the trigger), and any non-obvious requirements (auth, dependencies, side effects). You may draw on the frontmatter `description:` field — paraphrase and condense it rather than echo it verbatim, and add anything notable from the body.

    Plain prose only — no markdown, bullets, headings, or labels. Under 60 words. Always produce a summary based on whatever the SKILL.md provides — never refuse.
    """

    private static let maxSkillContentCharacters = 6_000

    private static func userPrompt(skillContent: String) -> String {
        let trimmed = skillContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = trimmed.count > maxSkillContentCharacters
            ? String(trimmed.prefix(maxSkillContentCharacters)) + "\n…[truncated]"
            : trimmed
        return """
        Summarise this SKILL.md so a developer can decide whether the skill is worth importing.

        SKILL.md:
        ---
        \(truncated)
        ---
        """
    }

    private static func sanitizedSummary(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^[\"'“”‘’`]+|[\"'“”‘’`]+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(Summary|AI summary):\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 600 {
            text = String(text.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw GenerationError.emptyResponse }
        guard text.count >= 20 else { throw GenerationError.invalidResponse }
        let lowered = text.lowercased()
        if lowered.contains("insufficient information") || lowered.hasPrefix("i cannot summari") || lowered.hasPrefix("i can't summari") {
            throw GenerationError.invalidResponse
        }
        return text
    }

    private static func extractAssistantText(from message: JSONValue) -> String {
        guard let content = message["content"] else { return message["output"]?.stringValue ?? "" }
        switch content {
        case let .string(value): return value
        case let .array(blocks): return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return content.compactDescription
        }
    }
}
