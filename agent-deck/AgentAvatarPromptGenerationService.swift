import Foundation

@MainActor
final class AgentAvatarPromptGenerationService {
    enum GenerationError: LocalizedError {
        case emptyResponse
        case invalidResponse
        case timedOut
        case processExited(Int32)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Avatar prompt generation returned an empty response."
            case .invalidResponse: return "Avatar prompt generation returned an invalid prompt."
            case .timedOut: return "Avatar prompt generation timed out."
            case let .processExited(code): return "Avatar prompt generation process exited with code \(code)."
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
    private let timeoutNanoseconds: UInt64 = 20_000_000_000

    func generatePrompt(
        for agent: EffectiveAgentRecord,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String]
    ) async throws -> String {
        let userPrompt = Self.userPrompt(for: agent)
        if FoundationModelAutomationService.isFoundationModel(model) {
            let response = try await FoundationModelAutomationService.generateOneShot(
                prompt: userPrompt,
                systemPrompt: Self.systemPrompt,
                temperature: 0.7,
                maxTokens: 80
            )
            return try Self.sanitizedPrompt(response)
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
                    "--no-extensions",
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
                finish(runID: runID, result: .success(try Self.sanitizedPrompt(run.assistantText)))
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
    You write short prompts for Apple Image Playground.

    Return exactly one prompt, no markdown, no quotes, no labels.
    The prompt must be a positive visual description only.
    Avoid negative instructions such as “no people” or “no text”.
    Avoid words that imply people, faces, portraits, weapons, brands, logos, UI, or screenshots.
    Prefer simple symbolic software-development motifs and concrete objects.
    Use the agent's name, description, skills, and role to choose one distinctive primary motif.
    Do not copy examples verbatim; adapt the motif to the specific agent.

    Example prompt patterns:
    code brackets with connected nodes and sparkles, colorful abstract software development app icon, clean rounded illustration, simple gradient background, high contrast
    magnifying glass with checkmarks and code brackets, colorful abstract software development app icon, clean rounded illustration, simple gradient background, high contrast
    compass with connected nodes and code brackets, colorful abstract software development app icon, clean rounded illustration, simple gradient background, high contrast
    checklist with connected nodes and a small roadmap, colorful abstract software development app icon, clean rounded illustration, simple gradient background, high contrast
    open book with sparkles and code brackets, colorful abstract software development app icon, clean rounded illustration, simple gradient background, high contrast
    """

    private static func userPrompt(for agent: EffectiveAgentRecord) -> String {
        let frontmatter = agent.winningRecord?.rawFrontmatter
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n") ?? ""
        return """
        Create an Image Playground prompt for this coding agent.

        Agent name:
        \(agent.name)

        Agent frontmatter:
        ---
        \(frontmatter)
        ---

        Resolved description:
        \(agent.resolved.description)

        Resolved skills:
        \(agent.resolved.skills.joined(separator: ", "))
        """
    }

    private static func sanitizedPrompt(_ raw: String) throws -> String {
        var prompt = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = prompt.replacingOccurrences(of: #"^[\"'“”‘’`]+|[\"'“”‘’`]+$"#, with: "", options: .regularExpression)
        prompt = prompt.replacingOccurrences(of: #"^(Prompt|Image prompt):\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        prompt = String(prompt.prefix(260)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw GenerationError.emptyResponse }
        guard prompt.count >= 16 else { throw GenerationError.invalidResponse }
        return prompt
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
