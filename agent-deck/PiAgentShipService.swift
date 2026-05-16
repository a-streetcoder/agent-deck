import Foundation

@MainActor
final class PiAgentShipService {
    enum ShipError: LocalizedError {
        case noSelectedSession
        case noModel
        case noChanges
        case conflicts
        case emptyCommitMessage
        case timedOut
        case processExited(Int32)
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .noSelectedSession: return "Select a Pi Agent session before shipping."
            case .noModel: return "Choose a model before shipping."
            case .noChanges: return "There are no changes to commit."
            case .conflicts: return "Resolve conflicted files before shipping."
            case .emptyCommitMessage: return "Ship message generation returned an empty commit title."
            case .timedOut: return "Ship message generation timed out."
            case let .processExited(code): return "Ship message generation process exited with code \(code)."
            case let .rpc(message): return message
            }
        }
    }

    struct CommitMessage {
        let title: String
        let body: String
    }

    private final class Run {
        let client: PiRPCClient
        let completion: (Result<CommitMessage, Error>) -> Void
        var assistantText = ""
        var isFinished = false
        var timeoutTask: Task<Void, Never>?

        init(client: PiRPCClient, completion: @escaping (Result<CommitMessage, Error>) -> Void) {
            self.client = client
            self.completion = completion
        }
    }

    private var runsByID: [UUID: Run] = [:]
    private let timeoutNanoseconds: UInt64 = 30_000_000_000

    func generateCommitMessage(
        status: String,
        diff: String,
        model: AvailableModel,
        projectURL: URL,
        environment: [String: String],
        completion: @escaping (Result<CommitMessage, Error>) -> Void
    ) {
        if FoundationModelAutomationService.isFoundationModel(model) {
            Task { [status, diff] in
                do {
                    let text = try await FoundationModelAutomationService.generateOneShot(
                        prompt: foundationPrompt(status: status, diff: diff),
                        systemPrompt: Self.commitMessageSystemPrompt,
                        temperature: 0.2,
                        maxTokens: 320
                    )
                    completion(parseCommitMessage(text))
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
                    Self.commitMessageSystemPrompt,
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
                await MainActor.run { [weak self] in self?.finish(runID: runID, result: .failure(ShipError.timedOut)) }
            }
            client.prompt(prompt(status: status, diff: diff))
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
        guard let run = runsByID[runID], !run.isFinished, let event else { return }
        if event.type == "response", event.success == false {
            finish(runID: runID, result: .failure(ShipError.rpc(event.error?.compactDescription ?? event.data?.compactDescription ?? rawLine)))
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
            let text = extractAssistantText(from: message)
            finish(runID: runID, result: parseCommitMessage(text.isEmpty ? run.assistantText : text))
        default:
            break
        }
    }

    private func handleTermination(exitCode: Int32, runID: UUID) {
        guard let run = runsByID[runID], !run.isFinished else { return }
        finish(runID: runID, result: .failure(ShipError.processExited(exitCode)))
    }

    private func finish(runID: UUID, result: Result<CommitMessage, Error>) {
        guard let run = runsByID.removeValue(forKey: runID), !run.isFinished else { return }
        run.isFinished = true
        run.timeoutTask?.cancel()
        run.client.stop()
        run.completion(result)
    }

    private static let commitMessageSystemPrompt = """
    You are Agent Deck's git commit message generator. Your only job is to write a commit message from the supplied git status and staged diff.

    The commit message must be concise and explanatory: capture the concrete code or product change being committed, not the mechanical act of editing files. Prefer the intended behavior or user-visible outcome when the diff makes it clear.

    Return exactly this format, with no markdown:
    Title: <imperative commit title, max 72 chars>
    Body: <1-3 concise bullet points or one short paragraph>

    Requirements:
    - Title must be imperative, specific, and <= 72 characters
    - Body must explain what changed, not repeat filenames only
    - No quotes around the title
    - No markdown fences
    - Do not invent changes not supported by the status or diff
    """

    private func prompt(status: String, diff: String) -> String {
        """
        Generate a git commit message for these staged changes.

        Git status:
        \(status)

        Staged diff/stat:
        \(String(diff.prefix(12000)))
        """
    }

    private func foundationPrompt(status: String, diff: String) -> String {
        """
        Generate a git commit message for these staged changes.

        Git status:
        \(status)

        Staged diff/stat:
        \(String(diff.prefix(6000)))
        """
    }

    private func parseCommitMessage(_ text: String) -> Result<CommitMessage, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ShipError.emptyCommitMessage) }
        let lines = trimmed.components(separatedBy: .newlines)
        let title = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .replacingOccurrences(of: "Title:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return .failure(ShipError.emptyCommitMessage) }
        let body = lines.dropFirst().joined(separator: "\n")
            .replacingOccurrences(of: "Body:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(CommitMessage(title: String(title.prefix(120)), body: body))
    }

    private func extractAssistantText(from message: JSONValue) -> String {
        guard let content = message["content"] else { return "" }
        switch content {
        case let .string(value): return value
        case let .array(blocks):
            return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return content.compactDescription
        }
    }
}
