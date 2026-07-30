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
        let language = Self.detectTitleLanguage(from: firstMessage)
        startHelper(
            systemPrompt: Self.titleSystemPrompt(language: language),
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
        // Prefer the latest user message language; fall back to current title script if message is code-only.
        let language = Self.detectTitleLanguage(from: latestUserMessage, fallbackText: currentTitle)
        startHelper(
            systemPrompt: Self.titleUpdateSystemPrompt(language: language),
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

        let knownThinkingSuffixes = PiThinkingLevelCatalog.ordered
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
                ] + PiAgentLaunchArgumentBuilder.isolatedLaunchBaseArguments(
                    settings: AppSettingsStore.shared.settings,
                    projectURL: projectURL
                ) + [
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

    /// Script family used for session title generation (from user text, not app UI language).
    private enum TitleLanguage: String {
        case chinese
        case english
    }

    /**
     Detect title language from the conversation's first user message.

     Counts Han characters vs Latin letters after stripping code fences and common path/URL noise.
     Defaults to English when the signal is ambiguous (code-only, mixed, empty).

     - Parameters:
       - text: Primary sample (first message or latest user message).
       - fallbackText: Optional second sample (e.g. current title) when primary is code-heavy.
     - Returns: `.chinese` when Chinese script dominates; otherwise `.english`.
     */
    private static func detectTitleLanguage(from text: String, fallbackText: String? = nil) -> TitleLanguage {
        if let detected = scriptSignal(in: text) {
            return detected
        }
        if let fallbackText, let detected = scriptSignal(in: fallbackText) {
            return detected
        }
        return .english
    }

    /**
     Extract a language signal from free text.

     - Parameter text: Raw user or title text.
     - Returns: Detected language, or `nil` when not enough letters/Han to decide.
     */
    private static func scriptSignal(in text: String) -> TitleLanguage? {
        var sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        // Drop fenced code blocks — they skew English letter counts.
        sample = sample.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: " ",
            options: .regularExpression
        )
        // Drop inline code ticks content lightly by removing backticks only.
        sample = sample.replacingOccurrences(of: "`", with: " ")
        // Drop URLs / file paths-ish tokens.
        sample = sample.replacingOccurrences(
            of: #"https?://\S+"#,
            with: " ",
            options: .regularExpression
        )
        sample = sample.replacingOccurrences(
            of: #"(?:[\w.-]+/)+[\w.-]+"#,
            with: " ",
            options: .regularExpression
        )

        var han = 0
        var latin = 0
        for scalar in sample.unicodeScalars {
            if CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}").contains(scalar)
                || CharacterSet(charactersIn: "\u{3400}"..."\u{4DBF}").contains(scalar)
                || CharacterSet(charactersIn: "\u{F900}"..."\u{FAFF}").contains(scalar)
            {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                // Basic Latin + Latin-1 Supplement letters only for "English-ish" signal.
                let v = scalar.value
                if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                    || (0xC0...0x24F).contains(v)
                {
                    latin += 1
                }
            }
        }

        let total = han + latin
        // Need a few content characters; pure code/punctuation → undecided.
        guard total >= 2 else { return nil }
        // Chinese wins when Han is at least half of letter-like content, or absolute Han >= 2 with sparse Latin.
        if han >= 2 && han * 2 >= total {
            return .chinese
        }
        if han >= 4 && han >= latin {
            return .chinese
        }
        if latin >= 2 {
            return .english
        }
        return nil
    }

    /**
     Build the title-generation system prompt for the conversation language.

     - Parameter language: Language inferred from the first user message.
     - Returns: System prompt instructing the helper model.
     */
    private static func titleSystemPrompt(language: TitleLanguage) -> String {
        let languageRule = titleLanguageRule(language: language)
        let examples: String
        switch language {
        case .chinese:
            examples = """
            Examples:
            - 若用户想改 Liquid Glass 开关按钮以匹配主加号按钮，返回类似「优化 Liquid Glass 选项按钮」的标题，而不是「阅读文档」。
            - 若用户要修标题生成相关测试失败，返回类似「修复标题生成测试」的标题，而不是「排查测试失败」。
            """
        case .english:
            examples = """
            Examples:
            - If the user asks to read Liquid Glass documentation so a switch icon button can match the primary plus button, return a title like "Improve Liquid Glass Options Button", not "Reading Documentation".
            - If the user asks to debug failing title generation tests, return a title like "Fix Title Generation Tests", not "Inspecting Test Failures".
            """
        }
        let wordRule: String
        switch language {
        case .chinese:
            wordRule = """
            - 中文标题约 6–16 个汉字，或与用户目标同长度的简短短语
            - 不要英文 Title Case；用自然中文短语
            """
        case .english:
            wordRule = """
            - 3 to 7 words
            - Title Case
            """
        }
        return """
        You are \(AppBrand.displayName)'s session title generator. Your only job is to name a coding-agent chat from the user's first message.

        \(languageRule)

        The title must be concise and explanatory: capture the concrete goal or change the user is trying to achieve, not merely the immediate step the assistant may take. Prefer the intended product/code outcome over process wording.

        \(examples)

        Requirements:
        \(wordRule)
        - Preserve GitHub prefixes like "Issue #123" or "PR #123" when the message starts with one
        - Ignore slash commands, skill boilerplate, prompt boilerplate, and implementation text; title the user's goal
        - No quotes
        - Plain text only
        - No markdown formatting, bullets, code fences, heading markers, or emphasis
        - No trailing punctuation
        - Return only the title text
        """
    }

    /**
     Build the title-update system prompt for the conversation language.

     - Parameter language: Language inferred from the latest user message (fallback: current title).
     - Returns: System prompt for KEEP / rewrite decisions.
     */
    private static func titleUpdateSystemPrompt(language: TitleLanguage) -> String {
        let languageRule = titleLanguageRule(language: language)
        let wordRule: String
        switch language {
        case .chinese:
            wordRule = """
            - 新标题使用中文，约 6–16 个汉字的自然短语（不要英文 Title Case）
            """
        case .english:
            wordRule = """
            - New titles must be 3 to 7 words, Title Case, no quotes, plain text only, no markdown formatting, bullets, code fences, heading markers, or emphasis, no trailing punctuation
            """
        }
        return """
        You update \(AppBrand.displayName) coding-agent session titles. Decide whether the latest user message and current plan meaningfully change the session's main goal.

        \(languageRule)

        Requirements:
        - If the current title still fits, return exactly: KEEP
        - If the title should change, return only the new title
        \(wordRule)
        - Prefer the concrete product/code outcome over process wording
        - Do not change titles for minor follow-ups, progress updates, or implementation details
        - KEEP is always the ASCII token KEEP regardless of title language
        """
    }

    /**
     Language policy injected into title helper prompts.

     - Parameter language: Inferred conversation language from user text.
     - Returns: Explicit instruction so the model matches the first-message language.
     */
    private static func titleLanguageRule(language: TitleLanguage) -> String {
        switch language {
        case .chinese:
            return """
            Language policy (mandatory):
            - The user's first message is in Chinese. Write the session title in Simplified Chinese (简体中文).
            - Match the user's Chinese phrasing of the goal.
            - Keep technical terms, product names, file names, and code identifiers in their original form when clearer (e.g. Liquid Glass, RPC, MCP).
            - Do not return an English Title-Case title for a Chinese first message.
            """
        case .english:
            return """
            Language policy (mandatory):
            - The user's first message is in English (or non-Chinese). Write the session title in English.
            - Use Title Case for normal English titles.
            - Keep product/code identifiers unchanged when needed.
            """
        }
    }

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
        let rejected = [
            "new chat", "chat title", "session title", "untitled", "draft",
            "新会话", "新聊天", "会话标题", "聊天标题", "未命名", "草稿"
        ]
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
