import Foundation

enum PiAgentSessionKind: String, Codable, CaseIterable, Identifiable {
    case project = "Project"
    case issue = "Issue"
    case changesReview = "Changes Review"

    var id: String { rawValue }
}

enum PiAgentRunStatus: String, Codable, CaseIterable, Identifiable {
    case draft = "Draft"
    case starting = "Starting"
    case running = "Running"
    case idle = "Idle"
    case stopped = "Stopped"
    case failed = "Failed"
    case completed = "Completed"

    var id: String { rawValue }

    var isActive: Bool {
        self == .starting || self == .running
    }
}

enum PiAgentInputMode: String, CaseIterable, Identifiable {
    case prompt = "Send"
    case steer = "Steer"
    case followUp = "Follow Up"

    var id: String { rawValue }
}

enum PiSubagentRunStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case queued
    case starting
    case running
    case blocked
    case completed
    case failed
    case stopped
    case disconnected

    var id: String { rawValue }

    var isActive: Bool {
        self == .queued || self == .starting || self == .running || self == .blocked
    }
}

enum PiSubagentSupervisorRequestStatus: String, Codable, Hashable, Identifiable {
    case pending
    case answered
    case cancelled

    var id: String { rawValue }
}

enum PiSubagentSupervisorRequestKind: String, Codable, Hashable, Identifiable {
    case progressUpdate = "progress_update"
    case needDecision = "need_decision"
    case interviewRequest = "interview_request"

    var id: String { rawValue }

    var isBlocking: Bool {
        self == .needDecision || self == .interviewRequest
    }
}

struct PiSubagentSupervisorRequest: Identifiable, Codable, Hashable {
    var id: String
    var bridgeRequestID: String?
    var runID: UUID
    var parentSessionID: UUID
    var childID: UUID?
    var kind: PiSubagentSupervisorRequestKind
    var title: String
    var message: String
    var status: PiSubagentSupervisorRequestStatus
    var response: String?
    var createdAt: Date
    var updatedAt: Date
}

struct PiManagedSubagentBridgeRequest: Codable, Hashable {
    var agent: String
    var task: String
    var continueSubagentID: String?
    var reads: [String]?
}

struct PiManagedParallelTaskRequest: Codable, Hashable {
    var agent: String
    var task: String
}

struct PiManagedParallelBridgeRequest: Codable, Hashable {
    var tasks: [PiManagedParallelTaskRequest]
    var concurrency: Int?
    var worktree: Bool?
}

struct PiSupervisorAnswerBridgeRequest: Codable, Hashable {
    var requestID: String
    var response: String
}

struct PiSessionPlanSetBridgeRequest: Codable, Hashable {
    var items: [PiSessionPlanBridgeItem]
}

struct PiSessionPlanUpdateBridgeRequest: Codable, Hashable {
    var updates: [PiSessionPlanBridgeUpdate]
}

struct PiSystemPromptAuditBridgeRequest: Codable, Hashable {
    var scope: String?
    var parentSessionID: String?
    var runID: String?
    var agent: String?
    var systemPrompt: String
}

struct PiNativeAskBridgeRequest: Codable, Hashable {
    var question: String
    var context: String?
    var options: [JSONValue]?
    var allowMultiple: Bool?
    var allowFreeform: Bool?
    var allowComment: Bool?
    var timeout: Double?

    var normalizedOptions: [PiNativeAskOption] {
        (options ?? []).compactMap { value in
            if let title = value.stringValue {
                return PiNativeAskOption(title: title, description: nil)
            }
            guard case let .object(object) = value,
                  let title = object["title"]?.stringValue,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PiNativeAskOption(title: title, description: object["description"]?.stringValue)
        }
    }
}

struct PiNativeAskOption: Codable, Hashable {
    var title: String
    var description: String?
}

struct PiSessionPlanBridgeItem: Codable, Hashable {
    var id: String?
    var title: String
    var status: PiSessionPlanItemStatus?
}

struct PiSessionPlanBridgeUpdate: Codable, Hashable {
    var id: String
    var title: String?
    var status: PiSessionPlanItemStatus?
}

enum PiSessionPlanItemStatus: String, Codable, Hashable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done
    case blocked
    case skipped

    var displayName: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .blocked: return "Blocked"
        case .skipped: return "Skipped"
        }
    }
}

struct PiSessionPlanItemRecord: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: PiSessionPlanItemStatus
    var updatedAt: Date
}

enum PiSessionPlanEventKind: String, Codable, Hashable {
    case created
    case updated
    case replaced
    case cleared
}

struct PiSessionPlanRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var items: [PiSessionPlanItemRecord]
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case items
        case createdAt
        case updatedAt
    }

    init(id: UUID = UUID(), sessionID: UUID, items: [PiSessionPlanItemRecord], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        items = try container.decode([PiSessionPlanItemRecord].self, forKey: .items)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct PiSessionPlanEventRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var planID: UUID
    var kind: PiSessionPlanEventKind
    var items: [PiSessionPlanItemRecord]
    var timestamp: Date
}

enum PiSubagentRunMode: String, Codable, Hashable {
    case single
    case parallel

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == Self.single.rawValue ? .single : .parallel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PiSubagentWorktreeStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case active
    case patchReady
    case applied
    case discarded
    case failed

    var id: String { rawValue }
}

struct PiSubagentGraphEdgeRecord: Identifiable, Codable, Hashable {
    var id: String
    var fromChildID: UUID
    var toChildID: UUID
}

enum PiSubagentExpectedOutcome: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case reportOnly
    case editFilesInWorktree
    case writeProjectFile
    case directProjectWrites

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .reportOnly: return "Report only"
        case .editFilesInWorktree: return "Edit files in worktree"
        case .writeProjectFile: return "Write/update project file"
        case .directProjectWrites: return "Direct project writes"
        }
    }
}

struct PiSubagentChildRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var runID: UUID
    var index: Int
    var agentName: String
    var task: String?
    var status: PiSubagentRunStatus
    var model: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var readFirstPaths: [String]?
    var currentTool: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var toolCount: Int?
    var durationMs: Int?
    var artifactDirectory: String?
    var sessionFile: String?
    var outputPath: String?
    var worktreePath: String?
    var launchCommand: String?
    var executionRunID: UUID?
    var summary: String?
    var error: String?
    var dependencies: [UUID]?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct PiSubagentRunRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var parentSessionID: UUID
    var mode: PiSubagentRunMode
    var status: PiSubagentRunStatus
    var agentName: String
    var task: String
    var model: String?
    var thinking: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var readFirstPaths: [String]?
    var tools: [String]
    var skills: [String]
    var concurrencyLimit: Int?
    var worktreePolicy: String?
    var aggregateSummary: String?
    var artifactDirectory: String
    var outputPath: String?
    var worktreePath: String?
    var parentRepoPath: String?
    var baseCommit: String?
    var isWorktreeIsolated: Bool?
    var worktreeStatus: PiSubagentWorktreeStatus?
    var worktreePatchPath: String?
    var childSessionID: UUID?
    var childPiSessionFile: String?
    var launchCommand: String?
    var summary: String?
    var error: String?
    var child: PiSubagentChildRecord?
    var children: [PiSubagentChildRecord]?
    var graphEdges: [PiSubagentGraphEdgeRecord]?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var durationMs: Int?
}

extension PiSubagentRunRecord {
    static func failedPlaceholder(parentSessionID: UUID, agentName: String, task: String, error: String) -> PiSubagentRunRecord {
        let now = Date()
        return PiSubagentRunRecord(
            id: UUID(),
            parentSessionID: parentSessionID,
            mode: .single,
            status: .failed,
            agentName: agentName,
            task: task,
            model: nil,
            thinking: nil,
            expectedOutcome: nil,
            requestedOutputPath: nil,
            allowOverwrite: nil,
            readFirstPaths: nil,
            tools: [],
            skills: [],
            concurrencyLimit: nil,
            worktreePolicy: nil,
            aggregateSummary: nil,
            artifactDirectory: "",
            outputPath: nil,
            worktreePath: nil,
            parentRepoPath: nil,
            baseCommit: nil,
            isWorktreeIsolated: nil,
            worktreeStatus: nil,
            worktreePatchPath: nil,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: error,
            child: nil,
            children: nil,
            graphEdges: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            durationMs: 0
        )
    }
}

struct PiAgentImageAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var mimeType: String
    var data: String
    var sizeBytes: Int
    var fileReference: String?
    var dimensionNote: String?

    nonisolated init(id: UUID = UUID(), name: String, mimeType: String, data: String, sizeBytes: Int, fileReference: String? = nil, dimensionNote: String? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.sizeBytes = sizeBytes
        self.fileReference = fileReference
        self.dimensionNote = dimensionNote
    }

    nonisolated var rpcPayload: [String: String] {
        ["type": "image", "data": data, "mimeType": mimeType]
    }
}

struct PiAgentModelOption: Identifiable, Codable, Hashable {
    var provider: String
    var id: String
    var name: String?
    var contextWindow: Int?
    var maxOutput: Int?
    var supportsThinking: Bool?
    var supportedThinkingLevels: [String]?
    var supportsImages: Bool?

    var displayName: String { name?.isEmpty == false ? name! : id }
    var selectionID: String { "\(provider)/\(id)" }

    init(
        provider: String,
        id: String,
        name: String?,
        contextWindow: Int?,
        maxOutput: Int? = nil,
        supportsThinking: Bool?,
        supportedThinkingLevels: [String]?,
        supportsImages: Bool?
    ) {
        self.provider = provider
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.supportsThinking = supportsThinking
        self.supportedThinkingLevels = supportedThinkingLevels
        self.supportsImages = supportsImages
    }
}

struct PiAgentContextBreakdownItem: Identifiable, Codable, Hashable {
    var id: String { key }

    var key: String
    var title: String
    var tokens: Int?
    var percent: Double?
    var detail: String?

    init(key: String, title: String, tokens: Int?, percent: Double?, detail: String? = nil) {
        self.key = key
        self.title = title
        self.tokens = tokens
        self.percent = percent
        self.detail = detail
    }
}

struct PiAgentContextBreakdownEstimateRow: Identifiable, Hashable {
    enum Source: String, Hashable {
        case estimated
        case rpcAggregate
    }

    var id: String { key }

    var key: String
    var title: String
    var tokens: Int?
    var percent: Double?
    var detail: String?
    var source: Source
}

struct PiAgentContextBreakdownEstimate: Hashable {
    var rows: [PiAgentContextBreakdownEstimateRow]
    var note: String
}

struct PiAgentPromptCompositionRow: Identifiable, Hashable {
    var id: String { key }

    var key: String
    var title: String
    var tokens: Int
    var percent: Double
}

struct PiAgentPromptCompositionEstimate: Hashable {
    var rows: [PiAgentPromptCompositionRow]
    var totalTokens: Int
}

private extension NSRange {
    var locationOrNil: Int? { location == NSNotFound ? nil : location }
}

struct PiAgentContextEstimateBuilder {
    static func build(
        session: PiAgentSessionRecord,
        transcript: [PiAgentTranscriptEntry],
        fallbackModels: [AvailableModel] = []
    ) -> PiAgentContextBreakdownEstimate {
        _ = fallbackModels
        guard let contextWindow = positive(session.contextWindow) else {
            return PiAgentContextBreakdownEstimate(
                rows: [],
                note: "Estimated rows need RPC context totals before \(AppBrand.displayName) can derive a useful breakdown."
            )
        }

        let usedTokens = max(session.contextTokens ?? 0, 0)
        let inputTokens = max(session.inputTokens ?? 0, 0)
        let outputTokens = max(session.outputTokens ?? 0, 0)
        let cacheTokens = max((session.cacheReadTokens ?? 0) + (session.cacheWriteTokens ?? 0), 0)

        var rows: [PiAgentContextBreakdownEstimateRow] = []
        var accountedUsedTokens = 0

        func clampedToRemainingUsed(_ tokens: Int) -> Int {
            min(max(tokens, 0), max(usedTokens - accountedUsedTokens, 0))
        }

        if inputTokens > 0 {
            let tokens = clampedToRemainingUsed(inputTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedInputTokens",
                title: "Prompt input",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if outputTokens > 0 {
            let tokens = clampedToRemainingUsed(outputTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedOutputTokens",
                title: "Model output",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if cacheTokens > 0 {
            let tokens = clampedToRemainingUsed(cacheTokens)
            accountedUsedTokens += tokens
            rows.append(.init(
                key: "estimatedCacheTokens",
                title: "Cache read/write",
                tokens: tokens,
                percent: percent(tokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        if accountedUsedTokens == 0 {
            let rawMessageTokens = estimatedTranscriptTokens(transcript)
            let messageTokens = min(rawMessageTokens, usedTokens)
            if messageTokens > 0 || rawMessageTokens > 0 {
                accountedUsedTokens += messageTokens
                rows.append(.init(
                    key: "estimatedMessages",
                    title: "Visible transcript",
                    tokens: messageTokens,
                    percent: percent(messageTokens, of: contextWindow),
                    detail: rawMessageTokens > messageTokens
                        ? "Estimated from visible user, assistant, tool, and thinking transcript entries; clamped to RPC used tokens."
                        : "Estimated from visible user, assistant, tool, and thinking transcript entries.",
                    source: .estimated
                ))
            }
        }

        let otherUsedTokens = max(usedTokens - accountedUsedTokens, 0)
        if otherUsedTokens > 0 {
            rows.append(.init(
                key: "estimatedOtherUsedContext",
                title: "Unattributed used context",
                tokens: otherUsedTokens,
                percent: percent(otherUsedTokens, of: contextWindow),
                detail: nil,
                source: .rpcAggregate
            ))
        }

        let freeTokens = max(contextWindow - usedTokens, 0)
        rows.append(.init(
            key: "estimatedFreeSpace",
            title: "Free space",
            tokens: freeTokens,
            percent: percent(freeTokens, of: contextWindow),
            detail: nil,
            source: .estimated
        ))

        return PiAgentContextBreakdownEstimate(
            rows: rows,
            note: "Estimated from Pi RPC token totals; exact prompt, tool, and message categories aren’t exposed."
        )
    }

    static func buildPromptComposition(systemPrompt: String?) -> PiAgentPromptCompositionEstimate? {
        guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), systemPrompt.isEmpty == false else {
            return nil
        }

        let prompt = systemPrompt as NSString
        let lower = systemPrompt.lowercased() as NSString
        let fullLength = prompt.length
        let totalTokens = estimatedPromptTokens(systemPrompt)
        guard totalTokens > 0 else { return nil }

        let skillsRange = blockRange(
            in: lower,
            startMarker: "<available_skills>",
            endMarker: "</available_skills>"
        )
        let toolsStart = lower.range(of: "available tools:").locationOrNil
        let projectStart = lower.range(of: "# project context").locationOrNil
        let skillsStart = skillsRange?.location

        func nextBoundary(after start: Int, candidates: [Int?]) -> Int {
            candidates.compactMap { $0 }.filter { $0 > start }.min() ?? fullLength
        }

        var ranges: [(key: String, title: String, range: NSRange)] = []
        if let toolsStart {
            ranges.append((
                "promptTools",
                "Tool descriptions",
                NSRange(location: toolsStart, length: nextBoundary(after: toolsStart, candidates: [projectStart, skillsStart]) - toolsStart)
            ))
        }
        if let projectStart {
            ranges.append((
                "promptProjectContext",
                "Project context",
                NSRange(location: projectStart, length: nextBoundary(after: projectStart, candidates: [skillsStart]) - projectStart)
            ))
        }
        if let skillsRange {
            ranges.append(("promptSkills", "Skill catalog", skillsRange))
        }

        let firstSectionStart = [toolsStart, projectStart, skillsStart].compactMap { $0 }.min() ?? fullLength
        if firstSectionStart > 0 {
            ranges.append(("promptCore", "Core instructions", NSRange(location: 0, length: firstSectionStart)))
        }

        var rows = ranges.compactMap { item -> PiAgentPromptCompositionRow? in
            guard item.range.location >= 0,
                  item.range.length > 0,
                  NSMaxRange(item.range) <= fullLength else { return nil }
            let tokens = estimatedPromptTokens(prompt.substring(with: item.range))
            guard tokens > 0 else { return nil }
            return .init(key: item.key, title: item.title, tokens: tokens, percent: percent(tokens, of: totalTokens))
        }

        let accounted = rows.reduce(0) { $0 + $1.tokens }
        let otherTokens = max(totalTokens - accounted, 0)
        if otherTokens > 50 {
            rows.append(.init(
                key: "promptOther",
                title: "Other prompt content",
                tokens: otherTokens,
                percent: percent(otherTokens, of: totalTokens)
            ))
        }

        rows.sort { $0.tokens > $1.tokens }
        return .init(rows: rows, totalTokens: totalTokens)
    }

    static func parseTokenCount(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else { return nil }
        let multiplier: Double
        let numberText: String
        if trimmed.hasSuffix("k") {
            multiplier = 1_000
            numberText = String(trimmed.dropLast())
        } else if trimmed.hasSuffix("m") {
            multiplier = 1_000_000
            numberText = String(trimmed.dropLast())
        } else {
            multiplier = 1
            numberText = trimmed.replacingOccurrences(of: ",", with: "")
        }
        guard let number = Double(numberText.replacingOccurrences(of: ",", with: "")) else { return nil }
        return max(Int((number * multiplier).rounded()), 0)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func percent(_ tokens: Int, of contextWindow: Int) -> Double {
        guard contextWindow > 0 else { return 0 }
        return min(max((Double(max(tokens, 0)) / Double(contextWindow)) * 100, 0), 100)
    }

    private static func estimatedTranscriptTokens(_ transcript: [PiAgentTranscriptEntry]) -> Int {
        transcript.reduce(0) { total, entry in
            guard isProviderVisibleEstimateRole(entry.role) else { return total }
            let text = transcriptTextForEstimate(entry)
            guard text.isEmpty == false else { return total }
            return total + Int(ceil(Double(text.count) / 4.0))
        }
    }

    private static func estimatedPromptTokens(_ text: String) -> Int {
        guard text.isEmpty == false else { return 0 }
        return Int(ceil(Double(text.count) / 3.5))
    }

    private static func blockRange(in text: NSString, startMarker: String, endMarker: String) -> NSRange? {
        let start = text.range(of: startMarker)
        guard start.location != NSNotFound else { return nil }
        let endSearch = NSRange(location: NSMaxRange(start), length: text.length - NSMaxRange(start))
        let end = text.range(of: endMarker, options: [], range: endSearch)
        guard end.location != NSNotFound else {
            return NSRange(location: start.location, length: text.length - start.location)
        }
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    private static func isProviderVisibleEstimateRole(_ role: PiAgentTranscriptRole) -> Bool {
        switch role {
        case .user, .assistant, .tool, .thinking:
            return true
        case .status, .error, .stderr, .raw:
            return false
        }
    }

    private static func transcriptTextForEstimate(_ entry: PiAgentTranscriptEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.role == .tool else { return text }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return text }
        if text.isEmpty { return title }
        return "\(title)\n\(text)"
    }

}

struct PiAgentSessionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PiAgentSessionKind
    var title: String
    var projectPath: String
    var projectName: String
    var repository: String?
    var issueNumber: Int?
    var issueURL: URL?
    var piSessionFile: String?
    var piSessionId: String?
    var model: String?
    var modelProvider: String?
    var modelOverrideID: String?
    var modelOverrideProvider: String?
    var commandInvocations: [String]?
    var thinkingLevel: String?
    var launchCommand: String?
    var branchName: String?
    var worktreePath: String?
    var status: PiAgentRunStatus
    var lastError: String?
    var lastSummary: String?
    var needsAttention: Bool
    var isPinned: Bool
    var lastNotificationAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalTokens: Int?
    var toolCalls: Int?
    var toolResults: Int?
    var contextTokens: Int?
    var contextWindow: Int?
    var contextPercent: Double?
    var contextBreakdown: [PiAgentContextBreakdownItem]
    var cost: Double?
    var finalSystemPrompt: String?
    var finalSystemPromptCapturedAt: Date?
    var pendingSteeringMessages: [String]
    var pendingFollowUpMessages: [String]
    var subagentsEnabled: Bool
    var agentSelection: Set<String>?
    var isCompacting: Bool
    var isTitleUserEdited: Bool
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        if let issueNumber {
            return "#\(issueNumber) \(title)"
        }
        return title
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, projectPath, projectName, repository, issueNumber, issueURL, piSessionFile, piSessionId
        case model, modelProvider, modelOverrideID, modelOverrideProvider, commandInvocations, thinkingLevel, launchCommand, branchName, worktreePath
        case status, lastError, lastSummary, needsAttention, isPinned, lastNotificationAt
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens, toolCalls, toolResults, contextTokens, contextWindow, contextPercent, contextBreakdown, cost
        case finalSystemPrompt, finalSystemPromptCapturedAt
        case pendingSteeringMessages, pendingFollowUpMessages, subagentsEnabled, agentSelection, isCompacting, isTitleUserEdited, createdAt, updatedAt
    }

    init(
        id: UUID,
        kind: PiAgentSessionKind,
        title: String,
        projectPath: String,
        projectName: String,
        repository: String?,
        issueNumber: Int?,
        issueURL: URL?,
        piSessionFile: String?,
        piSessionId: String?,
        model: String?,
        modelProvider: String?,
        modelOverrideID: String?,
        modelOverrideProvider: String?,
        commandInvocations: [String]? = nil,
        thinkingLevel: String?,
        launchCommand: String?,
        branchName: String?,
        worktreePath: String?,
        status: PiAgentRunStatus,
        lastError: String?,
        lastSummary: String?,
        needsAttention: Bool,
        isPinned: Bool = false,
        lastNotificationAt: Date?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        totalTokens: Int?,
        toolCalls: Int?,
        toolResults: Int?,
        contextTokens: Int?,
        contextWindow: Int?,
        contextPercent: Double?,
        contextBreakdown: [PiAgentContextBreakdownItem] = [],
        cost: Double?,
        finalSystemPrompt: String? = nil,
        finalSystemPromptCapturedAt: Date? = nil,
        pendingSteeringMessages: [String],
        pendingFollowUpMessages: [String],
        subagentsEnabled: Bool,
        agentSelection: Set<String>? = nil,
        isCompacting: Bool = false,
        isTitleUserEdited: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.projectPath = projectPath
        self.projectName = projectName
        self.repository = repository
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.piSessionFile = piSessionFile
        self.piSessionId = piSessionId
        self.model = model
        self.modelProvider = modelProvider
        self.modelOverrideID = modelOverrideID
        self.modelOverrideProvider = modelOverrideProvider
        self.commandInvocations = commandInvocations
        self.thinkingLevel = thinkingLevel
        self.launchCommand = launchCommand
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.status = status
        self.lastError = lastError
        self.lastSummary = lastSummary
        self.needsAttention = needsAttention
        self.isPinned = isPinned
        self.lastNotificationAt = lastNotificationAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.contextBreakdown = contextBreakdown
        self.cost = cost
        self.finalSystemPrompt = finalSystemPrompt
        self.finalSystemPromptCapturedAt = finalSystemPromptCapturedAt
        self.pendingSteeringMessages = pendingSteeringMessages
        self.pendingFollowUpMessages = pendingFollowUpMessages
        self.subagentsEnabled = subagentsEnabled
        self.agentSelection = agentSelection
        self.isCompacting = isCompacting
        self.isTitleUserEdited = isTitleUserEdited
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(PiAgentSessionKind.self, forKey: .kind),
            title: try container.decode(String.self, forKey: .title),
            projectPath: try container.decode(String.self, forKey: .projectPath),
            projectName: try container.decode(String.self, forKey: .projectName),
            repository: try container.decodeIfPresent(String.self, forKey: .repository),
            issueNumber: try container.decodeIfPresent(Int.self, forKey: .issueNumber),
            issueURL: try container.decodeIfPresent(URL.self, forKey: .issueURL),
            piSessionFile: try container.decodeIfPresent(String.self, forKey: .piSessionFile),
            piSessionId: try container.decodeIfPresent(String.self, forKey: .piSessionId),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            modelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider),
            modelOverrideID: try container.decodeIfPresent(String.self, forKey: .modelOverrideID),
            modelOverrideProvider: try container.decodeIfPresent(String.self, forKey: .modelOverrideProvider),
            commandInvocations: try container.decodeIfPresent([String].self, forKey: .commandInvocations),
            thinkingLevel: try container.decodeIfPresent(String.self, forKey: .thinkingLevel),
            launchCommand: try container.decodeIfPresent(String.self, forKey: .launchCommand),
            branchName: try container.decodeIfPresent(String.self, forKey: .branchName),
            worktreePath: try container.decodeIfPresent(String.self, forKey: .worktreePath),
            status: try container.decode(PiAgentRunStatus.self, forKey: .status),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            lastSummary: try container.decodeIfPresent(String.self, forKey: .lastSummary),
            needsAttention: try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            lastNotificationAt: try container.decodeIfPresent(Date.self, forKey: .lastNotificationAt),
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens),
            cacheReadTokens: try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens),
            cacheWriteTokens: try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens),
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens),
            toolCalls: try container.decodeIfPresent(Int.self, forKey: .toolCalls),
            toolResults: try container.decodeIfPresent(Int.self, forKey: .toolResults),
            contextTokens: try container.decodeIfPresent(Int.self, forKey: .contextTokens),
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow),
            contextPercent: try container.decodeIfPresent(Double.self, forKey: .contextPercent),
            contextBreakdown: try container.decodeIfPresent([PiAgentContextBreakdownItem].self, forKey: .contextBreakdown) ?? [],
            cost: try container.decodeIfPresent(Double.self, forKey: .cost),
            finalSystemPrompt: try container.decodeIfPresent(String.self, forKey: .finalSystemPrompt),
            finalSystemPromptCapturedAt: try container.decodeIfPresent(Date.self, forKey: .finalSystemPromptCapturedAt),
            pendingSteeringMessages: try container.decodeIfPresent([String].self, forKey: .pendingSteeringMessages) ?? [],
            pendingFollowUpMessages: try container.decodeIfPresent([String].self, forKey: .pendingFollowUpMessages) ?? [],
            subagentsEnabled: try container.decodeIfPresent(Bool.self, forKey: .subagentsEnabled) ?? true,
            agentSelection: try container.decodeIfPresent(Set<String>.self, forKey: .agentSelection),
            isCompacting: try container.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false,
            isTitleUserEdited: try container.decodeIfPresent(Bool.self, forKey: .isTitleUserEdited) ?? false,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

extension PiAgentSessionRecord {
    static func sessionListPrecedes(_ lhs: PiAgentSessionRecord, _ rhs: PiAgentSessionRecord, calendar: Calendar = .current) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }

        let updatedDayComparison = calendar.compare(lhs.updatedAt, to: rhs.updatedAt, toGranularity: .day)
        if updatedDayComparison != .orderedSame { return updatedDayComparison == .orderedDescending }

        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum PiAgentTranscriptRole: String, Codable, Hashable {
    case user
    case assistant
    case thinking
    case tool
    case status
    case error
    case stderr
    case raw
}

/// What Pi is doing *right now* during a live turn, derived from the RPC event
/// stream rather than from the last transcript entry. The transcript can only
/// say "the most recent thing that produced an entry"; it cannot tell a tool
/// that is still running apart from one that finished several seconds ago, and
/// it places the turn-start placeholder after streaming thinking. The runner
/// already handles every RPC event, so stamping the activity there is exact and
/// costs one dictionary write per event boundary.
enum PiAgentProcessingActivity: Equatable, Hashable {
    /// Turn started; model call in flight but nothing emitted yet.
    case preparing
    /// `thinking_delta` is streaming.
    case reasoning
    /// `text_delta` is streaming.
    case responding
    /// A tool is executing (between `tool_execution_start` and `…_end`).
    /// `detail` is the tool's target — a file name, command, or query —
    /// extracted from its arguments, or `nil` when there is nothing concise
    /// to show.
    case runningTool(name: String, detail: String?)
    /// A tool finished or a message ended; the next model call is in flight.
    case awaitingModel
}

struct PiAgentUIRequest: Identifiable, Hashable {
    enum Method: String, Hashable {
        case select
        case multiSelect
        case confirm
        case input
        case editor
    }

    enum ResponseFormat: Hashable {
        case plain
        case nativeAsk
    }

    let id: String
    let sessionID: UUID
    let method: Method
    let title: String
    let message: String?
    let options: [String]
    let optionDescriptions: [String: String]
    let placeholder: String?
    let prefill: String?
    let allowsFreeform: Bool
    let allowsComment: Bool
    let responseFormat: ResponseFormat

    func nativeAskSelectionResponseValue(selections: [String], comment: String) -> String {
        let trimmedSelections = selections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var object: [String: Any] = [
            "kind": "selection",
            "selections": trimmedSelections
        ]
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            object["comment"] = trimmedComment
        }
        return Self.jsonString(object)
    }

    func nativeAskFreeformResponseValue(_ text: String) -> String {
        Self.jsonString([
            "kind": "freeform",
            "text": text.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

struct PiAgentTranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var sessionID: UUID
    var role: PiAgentTranscriptRole
    var title: String
    var text: String
    var rawJSON: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: PiAgentTranscriptRole,
        title: String,
        text: String,
        rawJSON: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.title = title
        self.text = text
        self.rawJSON = rawJSON
        self.timestamp = timestamp
    }
}

nonisolated struct PiAgentRPCEvent: Decodable, Sendable {
    let type: String?
    let id: String?
    let command: String?
    let success: Bool?
    let data: JSONValue?
    let message: JSONValue?
    let messages: JSONValue?
    let toolResults: JSONValue?
    let assistantMessageEvent: JSONValue?
    let toolCallId: String?
    let toolName: String?
    let args: JSONValue?
    let partialResult: JSONValue?
    let result: JSONValue?
    let isError: Bool?
    let error: JSONValue?
    let method: String?
    let title: String?
    let options: JSONValue?
    let placeholder: String?
    let prefill: String?
    let steering: JSONValue?
    let followUp: JSONValue?
    let reason: String?
    let aborted: Bool?
    let willRetry: Bool?
    let errorMessage: String?
}

nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var compactDescription: String {
        switch self {
        case let .string(value): return value
        case let .number(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        case let .array(value): return value.map(\.compactDescription).joined(separator: ", ")
        case let .object(value):
            return value.keys.sorted().map { key in
                "\(key): \(value[key]?.compactDescription ?? "")"
            }.joined(separator: "\n")
        case .null: return "null"
        }
    }
}
