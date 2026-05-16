import Foundation

@MainActor
final class PiSessionTitleGenerationService {
    enum GenerationError: LocalizedError {
        case emptyResponse
        case invalidResponse
        case timedOut
        case processExited(Int32)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Title generation returned an empty response."
            case .invalidResponse: return "Title generation returned an invalid title."
            case .timedOut: return "Title generation timed out."
            case let .processExited(code): return "Title generation process exited with code \(code)."
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
    private let maxFirstMessageCharacters = 2_000
    private let maxTitleUpdateMessageCharacters = 2_000
    private let maxPlanItems = 12

    func generateTitle(
        for firstMessage: String,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        startHelper(
            systemPrompt: Self.titleSystemPrompt,
            userPrompt: prompt(for: firstMessage),
            model: model,
            projectURL: projectURL,
            environment: environment,
            completion: completion
        )
    }

    func updateTitle(
        currentTitle: String,
        latestUserMessage: String,
        planItems: [PiSessionPlanItemRecord],
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        startHelper(
            systemPrompt: Self.titleUpdateSystemPrompt,
            userPrompt: updatePrompt(currentTitle: currentTitle, latestUserMessage: latestUserMessage, planItems: planItems),
            model: model,
            projectURL: projectURL,
            environment: environment,
            completion: completion
        )
    }

    static func runtimeModelArgument(modelID: String, thinkingLevel: String) -> String {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThinking = thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedThinking.isEmpty else { return trimmedModel }

        let knownThinkingSuffixes = ["off", "minimal", "low", "medium", "high", "xhigh"]
        let baseModel: String
        if let suffix = trimmedModel.split(separator: ":").last,
           knownThinkingSuffixes.contains(String(suffix)) {
            baseModel = trimmedModel.split(separator: ":").dropLast().joined(separator: ":")
        } else {
            baseModel = trimmedModel
        }
        return "\(baseModel):\(trimmedThinking)"
    }

    private func startHelper(
        systemPrompt: String,
        userPrompt: String,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if FoundationModelAutomationService.isFoundationModel(model) {
            Task { [systemPrompt, userPrompt] in
                do {
                    let rawTitle = try await FoundationModelAutomationService.generateOneShot(
                        prompt: userPrompt,
                        systemPrompt: systemPrompt,
                        temperature: 0.2,
                        maxTokens: 80
                    )
                    guard !rawTitle.isEmpty else {
                        completion(.failure(FoundationModelAutomationError.emptyResponse))
                        return
                    }
                    guard let title = Self.sanitizedTitle(rawTitle) else {
                        completion(.failure(GenerationError.invalidResponse))
                        return
                    }
                    completion(.success(title))
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }

        let runID = UUID()
        do {
            let client = try PiRPCClient(
                cwd: projectURL,
                provider: model.provider,
                modelArgument: Self.runtimeModelArgument(modelID: model.model, thinkingLevel: "off"),
                extraArguments: [
                    "--no-session",
                    "--no-extensions",
                    "--no-skills",
                    "--no-tools",
                    "--no-context-files",
                    "--no-prompt-templates",
                    "--no-themes",
                    "--system-prompt",
                    systemPrompt,
                    "--append-system-prompt",
                    "",
                ],
                environment: environment,
                onEvent: { [weak self] events in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for event in events {
                            self.handle(rawLine: event.rawLine, event: event.event, runID: runID)
                        }
                    }
                },
                onStderr: { _ in },
                onTermination: { [weak self] exitCode in
                    Task { @MainActor [weak self] in
                        self?.handleTermination(exitCode: exitCode, runID: runID)
                    }
                }
            )
            let run = Run(client: client, completion: completion)
            runsByID[runID] = run
            let timeout = self.timeoutNanoseconds
            run.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finish(runID: runID, result: .failure(GenerationError.timedOut))
                }
            }

            client.prompt(userPrompt)
        } catch {
            completion(.failure(error))
        }
    }

    func cancelAll() {
        for runID in Array(runsByID.keys) {
            finish(runID: runID, result: .failure(CancellationError()))
        }
    }

    private func handle(rawLine: String, event: PiAgentRPCEvent?, runID: UUID) {
        guard let run = runsByID[runID], !run.isFinished else { return }
        guard let event else { return }

        if event.type == "response", event.success == false {
            let message = event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine
            finish(runID: runID, result: .failure(GenerationError.rpc(message)))
            return
        }

        switch event.type {
        case "message_update":
            guard let assistantEvent = event.assistantMessageEvent else { return }
            let deltaType = assistantEvent["type"]?.stringValue ?? "update"
            guard deltaType == "text_delta" else { return }
            run.assistantText += assistantEvent["delta"]?.stringValue ?? ""
        case "message_end":
            guard let message = event.message,
                  (message["role"]?.stringValue ?? "assistant") == "assistant" else { return }
            let text = Self.extractAssistantText(from: message)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run.assistantText = text
            }
        case "agent_end", "turn_end":
            let rawTitle = run.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTitle.isEmpty else {
                finish(runID: runID, result: .failure(GenerationError.emptyResponse))
                return
            }
            guard let title = Self.sanitizedTitle(rawTitle) else {
                finish(runID: runID, result: .failure(GenerationError.invalidResponse))
                return
            }
            finish(runID: runID, result: .success(title))
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

    private static let titleSystemPrompt = """
    You are Agent Deck's session title generator. Your only job is to name a coding-agent chat from the user's first message.

    The title must be concise and explanatory: capture the concrete goal or change the user is trying to achieve, not merely the immediate step the assistant may take. Prefer the intended product/code outcome over process wording.

    Examples:
    - If the user asks to read Liquid Glass documentation so a switch icon button can match the primary plus button, return a title like "Improve Liquid Glass Options Button", not "Reading Documentation".
    - If the user asks to debug failing title generation tests, return a title like "Fix Title Generation Tests", not "Inspecting Test Failures".

    Requirements:
    - 3 to 7 words
    - Title Case
    - No quotes
    - Plain text only
    - No markdown formatting, bullets, code fences, heading markers, or emphasis
    - No trailing punctuation
    - Return only the title text
    """

    private static let titleUpdateSystemPrompt = """
    You update Agent Deck coding-agent session titles. Decide whether the latest user message and current plan meaningfully change the session's main goal.

    Requirements:
    - If the current title still fits, return exactly: KEEP
    - If the title should change, return only the new title
    - New titles must be 3 to 7 words, Title Case, no quotes, plain text only, no markdown formatting, bullets, code fences, heading markers, or emphasis, no trailing punctuation
    - Prefer the concrete product/code outcome over process wording
    - Do not change titles for minor follow-ups, progress updates, or implementation details
    """

    private func prompt(for firstMessage: String) -> String {
        let trimmedMessage = firstMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxFirstMessageCharacters)
        return """
        Generate a session title for this user's first message:
        <message>
        \(trimmedMessage)
        </message>
        """
    }

    private func updatePrompt(currentTitle: String, latestUserMessage: String, planItems: [PiSessionPlanItemRecord]) -> String {
        let trimmedTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = latestUserMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxTitleUpdateMessageCharacters)
        let planText = planItems.prefix(maxPlanItems).map { item in
            "- [\(item.status.rawValue)] \(item.title)"
        }.joined(separator: "\n")
        return """
        Current session title:
        <current_title>
        \(trimmedTitle)
        </current_title>

        Latest user message:
        <latest_user_message>
        \(trimmedMessage)
        </latest_user_message>

        Current plan:
        <plan>
        \(planText)
        </plan>
        """
    }

    private static func sanitizedTitle(_ rawTitle: String) -> String? {
        var title = rawTitle
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: #"^[\"'“”‘’`]+|[\"'“”‘’`]+$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"^[#*\-\s]+"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[\.!?;:,]+$"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }
        guard title.count <= 80 else { return nil }
        let lower = title.lowercased()
        let rejected = ["new chat", "chat title", "session title", "untitled", "draft"]
        guard !rejected.contains(lower) else { return nil }
        return String(title.prefix(60))
    }

    private static func extractAssistantText(from message: JSONValue) -> String {
        if let content = message["content"] {
            switch content {
            case let .string(value): return value
            case let .array(blocks):
                return blocks.compactMap { block in
                    let blockType = block["type"]?.stringValue
                    if blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" {
                        return block["text"]?.stringValue
                    }
                    return nil
                }.joined(separator: "\n")
            default:
                return ""
            }
        }
        return message["output"]?.stringValue ?? ""
    }
}
