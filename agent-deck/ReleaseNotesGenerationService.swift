import Foundation

/// One-shot helper that turns the commit subjects since the last release into a
/// friendly, user-facing release-notes body for the GitHub release and the
/// Sparkle update dialog. Mirrors `SkillDescriptionGenerationService`: a single
/// headless `pi` run with the default model, thinking disabled, and no
/// tools/skills/context so it stays fast and deterministic.
///
/// The output is a short markdown body WITHOUT a top-level heading — CI owns the
/// `## What's new in vX.Y` line so the version string has a single source of
/// truth. The text is editable in the release sheet and rides the annotated tag
/// into CI; if generation fails or the user clears it, CI falls back to listing
/// commits.
@MainActor
final class ReleaseNotesGenerationService {
    enum GenerationError: LocalizedError {
        case emptyResponse
        case timedOut
        case processExited(Int32)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "Release notes generation returned an empty response."
            case .timedOut: return "Release notes generation timed out."
            case let .processExited(code): return "Release notes generation process exited with code \(code)."
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
    private let timeoutNanoseconds: UInt64 = 45_000_000_000

    func generate(
        version: String,
        commitSubjects: [String],
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String]
    ) async throws -> String {
        let userPrompt = Self.userPrompt(version: version, commitSubjects: commitSubjects)
        if FoundationModelAutomationService.isFoundationModel(model) {
            let response = try await FoundationModelAutomationService.generateOneShot(
                prompt: userPrompt,
                systemPrompt: Self.systemPrompt,
                temperature: 0.4,
                maxTokens: 600
            )
            return try Self.sanitized(response)
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
                finish(runID: runID, result: .success(try Self.sanitized(run.assistantText)))
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

    // MARK: - Prompts

    private static let systemPrompt = """
    You are the release-notes writer for a macOS app called Agent Deck. You are given the git commit subjects for everything that changed SINCE THE LAST RELEASE — that list is exactly the new work in this version. Turn it into a short, friendly changelog that a non-technical user reads in the app's "Check for Updates" dialog and on the GitHub release page.

    Write GitHub-flavored markdown, grouped into these sections IN THIS ORDER. Include a section only when it has at least one item — never emit an empty section:

    ### ✨ New features
    ### 💪 Improvements
    ### 🐛 Bug fixes

    How to sort commits into sections:
    - New features: brand-new capabilities or screens the user can now use.
    - Improvements: things that already existed but got faster, clearer, or nicer (performance, polish, UX tweaks).
    - Bug fixes: things that were broken and now work.

    Rules:
    - Under each section, short plain-language bullets — one per user-visible change. Lead with what the user gets, not how it was built. Say "Smoother transcript scrolling", not "Cache markdown render product across vends".
    - Merge related commits into one bullet. Drop pure-internal work (refactors, tests, CI, dependency bumps, typo fixes) entirely unless it produced a user-visible effect — never list it as its own bullet.
    - Aim for 2–6 bullets total across all sections. If the only changes are internal housekeeping, output a single line (no section heading): "Performance and stability improvements." and nothing else.
    - Never invent anything not supported by the commits. Never include commit hashes, branch names, file paths, issue numbers, or author names.
    - Do NOT write a top-level title (no "# " or "## " line) and do NOT add a preamble or sign-off — the version heading is added automatically. Start a bullet with a capital letter, warm and clear, not marketing-hyped.

    Output only the markdown described above.
    """

    private static let maxCommits = 80

    private static func userPrompt(version: String, commitSubjects: [String]) -> String {
        let trimmed = commitSubjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let capped = trimmed.count > maxCommits ? Array(trimmed.prefix(maxCommits)) : trimmed
        let list = capped.map { "- \($0)" }.joined(separator: "\n")
        let body = list.isEmpty ? "(no commits found)" : list
        return """
        These are the commit subjects added since the previous release — i.e. everything new in Agent Deck \(version). Write the changelog for this version from them:

        \(body)
        """
    }

    private static func sanitized(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an accidental code fence if the model wrapped the list in ```.
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\n"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\n```$"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Drop a stray top-level title (# / ##) if the model added one despite
        // instructions — CI adds the "## What's new in vX.Y" heading. This must
        // NOT match the "### …" section headings, which we keep.
        text = text.replacingOccurrences(of: #"^#{1,2} [^#].*\n+"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GenerationError.emptyResponse }
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
