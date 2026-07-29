import Foundation

enum PiAgentSessionKind: String, Codable, CaseIterable, Identifiable {
    case project = "Project"
    /// Historical: created by removed Issues workspace. Still decoded for old session stores.
    case issue = "Issue"
    case changesReview = "Changes Review"
    case agent = "Agent"

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

/// A request from the `mcp` proxy bridge. `action` is one of list / search /
/// describe / call. The bridge derives the action from which key the model passed,
/// and may address a tool as `"server/tool"` or via separate `server` + `tool`.
struct PiMCPBridgeRequest: Codable, Hashable {
    var action: String
    var server: String?
    var tool: String?
    var query: String?
    var args: JSONValue?
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

nonisolated struct PiAgentUsageCostBreakdown: Codable, Hashable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    var total: Double?

    var cache: Double? { Self.sumKnown([cacheRead, cacheWrite]) }
    var resolvedTotal: Double? { total ?? Self.sumKnown([input, output, cacheRead, cacheWrite]) }

    func adding(_ other: PiAgentUsageCostBreakdown) -> PiAgentUsageCostBreakdown {
        PiAgentUsageCostBreakdown(
            input: Self.sumKnown([input, other.input]),
            output: Self.sumKnown([output, other.output]),
            cacheRead: Self.sumKnown([cacheRead, other.cacheRead]),
            cacheWrite: Self.sumKnown([cacheWrite, other.cacheWrite]),
            total: Self.sumKnown([total, other.total])
        )
    }

    static func from(_ value: JSONValue?) -> PiAgentUsageCostBreakdown? {
        guard let value else { return nil }
        if let total = value.flexibleNumber {
            return .init(input: nil, output: nil, cacheRead: nil, cacheWrite: nil, total: total)
        }
        guard case let .object(object) = value else { return nil }
        let breakdown = PiAgentUsageCostBreakdown(
            input: firstNumber(in: object, keys: ["input", "inputCost"]),
            output: firstNumber(in: object, keys: ["output", "outputCost"]),
            cacheRead: firstNumber(in: object, keys: ["cacheRead", "cache_read", "cacheReadCost"]),
            cacheWrite: firstNumber(in: object, keys: ["cacheWrite", "cache_write", "cacheWriteCost"]),
            total: firstNumber(in: object, keys: ["total", "totalCost", "cost"])
        )
        return breakdown.hasAnyValue ? breakdown : nil
    }

    static func verifiedAssistantCategoryCosts(from messages: [JSONValue], statsTotalCost: Double?) -> PiAgentUsageCostBreakdown? {
        guard let statsTotalCost else { return nil }
        var aggregate: PiAgentUsageCostBreakdown?
        for message in messages where message["role"]?.stringValue == "assistant" {
            guard let cost = PiAgentUsageCostBreakdown.from(message["usage"]?["cost"]), cost.hasCategories else { continue }
            let categoriesOnly = PiAgentUsageCostBreakdown(
                input: cost.input,
                output: cost.output,
                cacheRead: cost.cacheRead,
                cacheWrite: cost.cacheWrite,
                total: nil
            )
            aggregate = aggregate.map { $0.adding(categoriesOnly) } ?? categoriesOnly
        }
        guard var aggregate,
              let categoryTotal = sumKnown([aggregate.input, aggregate.output, aggregate.cacheRead, aggregate.cacheWrite]) else {
            return nil
        }
        let tolerance = max(0.000001, abs(statsTotalCost) * 0.000001)
        guard abs(categoryTotal - statsTotalCost) <= tolerance else { return nil }
        aggregate.total = statsTotalCost
        return aggregate
    }

    var hasAnyValue: Bool {
        input != nil || output != nil || cacheRead != nil || cacheWrite != nil || total != nil
    }

    var hasCategories: Bool {
        input != nil || output != nil || cacheRead != nil || cacheWrite != nil
    }

    static func sumKnown(_ values: [Double?]) -> Double? {
        var result: Double?
        for value in values {
            if let value { result = (result ?? 0) + value }
        }
        return result
    }

    private static func firstNumber(in object: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key]?.flexibleNumber { return value }
        }
        return nil
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
    var thinking: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var readFirstPaths: [String]?
    var currentTool: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int? = nil
    var cacheWriteTokens: Int? = nil
    var totalTokens: Int?
    var contextTokens: Int? = nil
    /// Runtime-computed cost for this subagent's own Pi session (set from the
    /// child's `get_session_stats` response, the same source as the parent's).
    var cost: Double? = nil
    /// Optional per-category cost reported by Pi assistant usage or stats.
    /// Nil means Pi did not report that category; zero means an explicit $0.00.
    var costBreakdown: PiAgentUsageCostBreakdown? = nil
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
    /// Snapshot of Agent Deck memory IDs injected into this child run at launch.
    var injectedMemoryIDs: [String]?
    /// Index-aligned titles for `injectedMemoryIDs`, captured when injected.
    var injectedMemoryTitles: [String]?
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
    /// Always stored in `index`-ascending order. All constructors build via
    /// `tasks.enumerated().map { index, _ in ... index: index }` and mutators
    /// only ever update children in place — never insert out-of-order. View
    /// code reads `children` directly without re-sorting.
    var children: [PiSubagentChildRecord]?
    var graphEdges: [PiSubagentGraphEdgeRecord]?
    /// Snapshot of Agent Deck memory IDs injected into this run at launch.
    var injectedMemoryIDs: [String]?
    /// Index-aligned titles for `injectedMemoryIDs`, captured when injected.
    var injectedMemoryTitles: [String]?
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
            injectedMemoryIDs: nil,
            injectedMemoryTitles: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            durationMs: 0
        )
    }
}

/// The attachments a user transcript entry recorded at send time (stored in the
/// entry's `rawJSON` by the runner). Decoded for chip rendering and for re-run,
/// which must resend the message with its original attachments intact.
struct PiAgentUserEntryAttachments: Codable {
    var images: [PiAgentImageAttachment]?
    var pastes: [PiAgentPasteAttachment]?
    var issue: PiAgentIssueAttachment?
}

extension PiAgentTranscriptEntry {
    var userAttachments: PiAgentUserEntryAttachments? {
        guard role == .user, let rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PiAgentUserEntryAttachments.self, from: data)
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

nonisolated struct PiAgentContextBreakdownItem: Identifiable, Codable, Hashable {
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
        // The injected MCP catalog (an appended block). Bounded by the blank line that
        // separates it from the next appended section (memory, APPEND_SYSTEM, …).
        let mcpStart = lower.range(of: "mcp tools (call through").locationOrNil

        func nextBoundary(after start: Int, candidates: [Int?]) -> Int {
            candidates.compactMap { $0 }.filter { $0 > start }.min() ?? fullLength
        }

        var ranges: [(key: String, title: String, range: NSRange)] = []
        if let toolsStart {
            ranges.append((
                "promptTools",
                "Tool descriptions",
                NSRange(location: toolsStart, length: nextBoundary(after: toolsStart, candidates: [projectStart, skillsStart, mcpStart]) - toolsStart)
            ))
        }
        if let projectStart {
            ranges.append((
                "promptProjectContext",
                "Project context",
                NSRange(location: projectStart, length: nextBoundary(after: projectStart, candidates: [skillsStart, mcpStart]) - projectStart)
            ))
        }
        if let skillsRange {
            ranges.append(("promptSkills", "Skill catalog", skillsRange))
        }
        if let mcpStart {
            let searchRange = NSRange(location: mcpStart, length: fullLength - mcpStart)
            let blankLine = prompt.range(of: "\n\n", options: [], range: searchRange).locationOrNil
            ranges.append(("promptMCP", "MCP catalog", NSRange(location: mcpStart, length: (blankLine ?? fullLength) - mcpStart)))
        }

        let firstSectionStart = [toolsStart, projectStart, skillsStart, mcpStart].compactMap { $0 }.min() ?? fullLength
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

enum PiAgentNoProjectMode: String, Codable, Hashable {
    case general
    case agentDeckBuilder
}

/// A per-parent-session child-launch field. Absence uses the persistent Models
/// value; `piDefault` deliberately bypasses it and lets Pi inherit from parent.
enum PiAgentSessionLaunchOverrideValue: Codable, Hashable {
    case piDefault
    case value(String)
}

struct PiAgentSessionAgentLaunchOverride: Codable, Hashable {
    var model: PiAgentSessionLaunchOverrideValue?
    var thinking: PiAgentSessionLaunchOverrideValue?

    var isEmpty: Bool { model == nil && thinking == nil }
}

nonisolated struct PiAgentSessionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PiAgentSessionKind
    var title: String
    var projectPath: String
    var projectName: String
    var repository: String?
    /// Historical Issues workspace metadata (optional; not set on new sessions).
    var issueNumber: Int?
    var issueURL: URL?
    var piSessionFile: String?
    /// Every Pi JSONL file owned by this logical Agent Deck session, including
    /// prior in-place rerun branches. Session deletion removes this full set.
    var ownedPiSessionFiles: [String]
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
    var sourceBranch: String?
    var status: PiAgentRunStatus
    var lastError: String?
    var lastSummary: String?
    var needsAttention: Bool
    var lastNotificationAt: Date?
    var lastUserMessageAt: Date?
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
    /// Optional per-category cost reported by Pi assistant usage or stats.
    /// Nil means Pi did not report that category; zero means an explicit $0.00.
    var costBreakdown: PiAgentUsageCostBreakdown?
    var finalSystemPrompt: String?
    var finalSystemPromptCapturedAt: Date?
    var pendingSteeringMessages: [String]
    var pendingFollowUpMessages: [String]
    var subagentsEnabled: Bool
    /// Whether Agent Deck memory was enabled when this session's Pi process
    /// (re)launched — stamped per launch in the runner, since memory injection
    /// is decided by the global setting at process start. Drives the resources
    /// popover's Memory section, mirroring `subagentsEnabled` for Deck agents.
    var memoryEnabled: Bool
    var agentSelection: Set<String>?
    /// Per-parent-session child launch overrides. These never modify agent or
    /// settings files and are applied only when a future child is launched.
    var agentLaunchOverrides: [String: PiAgentSessionAgentLaunchOverride]?
    var injectedExtensions: [String]?
    var agentName: String?
    var noProjectMode: PiAgentNoProjectMode?
    var isCompacting: Bool
    var isTitleUserEdited: Bool
    var forkedFromSessionID: UUID?
    var forkedFromParentTitle: String?
    var forkedFromUserMessageText: String?
    var forkedFromTranscriptSnapshot: String?
    /// Snapshot of the memory-context block recalled at this conversation's first
    /// launch. Replayed verbatim through `--append-system-prompt` on every later
    /// process relaunch of the SAME conversation (idle-park wake, model/thinking
    /// change, manual resume, recovery) so resumes restore the *same* system-prompt
    /// memory instead of re-running retrieval. A fork is a distinct session record,
    /// so it does not inherit this snapshot and recalls fresh as a new conversation.
    /// Pi's session file persists the conversation but not the system
    /// prompt, so the block must be re-supplied — but it must be the original bytes,
    /// not a fresh recall. See `memoryRecallCompleted`.
    var recalledMemoryPrompt: String?
    /// IDs of the memories in `recalledMemoryPrompt`, plus any pulled later via
    /// on-demand `agent_deck_memory_search`. Used to dedupe search results so the
    /// agent isn't handed memories it already has in context.
    var recalledMemoryIDs: [String]?
    /// True once launch-time recall has run for this logical conversation (even when
    /// it found nothing). Gates re-retrieval: a relaunch replays the snapshot rather
    /// than recalling again, which keeps the system prompt stable across the
    /// conversation and avoids duplicate "Memory Recalled" cards.
    var memoryRecallCompleted: Bool
    /// Persistent manual ordering override for the expanded session groups.
    /// Nil means unpinned; the timestamp orders multiple pins newest-first.
    var pinnedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    mutating func recordPiSessionFile(_ path: String?) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return }
        if let current = piSessionFile, !current.isEmpty, !ownedPiSessionFiles.contains(current) {
            ownedPiSessionFiles.append(current)
        }
        piSessionFile = path
        if !ownedPiSessionFiles.contains(path) {
            ownedPiSessionFiles.append(path)
        }
    }

    var displayTitle: String {
        // issueNumber is historical-only (removed Issues workspace); never surface it in UI.
        title
    }

    static let noProjectDisplayName = "General Chat"
    static let agentDeckBuilderDisplayName = "Agent Deck Builder"

    static var generalChatScratchRootURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("General Chats", isDirectory: true)
    }

    static var legacyNoProjectScratchRootURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("No Project Sessions", isDirectory: true)
    }

    /// Only normal Coding Agent project chats may run without a discovered project.
    /// Persisted records keep `projectPath`/`projectName` as strings for backwards
    /// compatibility; an empty path is the no-project sentinel.
    var isNoProject: Bool { kind == .project && projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var effectiveNoProjectMode: PiAgentNoProjectMode { noProjectMode ?? .general }
    var isAgentDeckBuilderSession: Bool { isNoProject && effectiveNoProjectMode == .agentDeckBuilder }

    var projectPathForProjectFeatures: String? {
        let trimmed = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var projectNameForDisplay: String {
        guard isNoProject else { return projectName }
        return isAgentDeckBuilderSession ? Self.agentDeckBuilderDisplayName : Self.noProjectDisplayName
    }

    /// The working tree the agent and toolbar actions operate in. Falls back to the
    /// project path for sessions that pre-date worktree isolation or that opted out.
    var repositoryRoot: String { worktreePath ?? projectPathForProjectFeatures ?? launchWorkingDirectory.path }

    var launchWorkingDirectory: URL {
        if let worktreePath { return URL(fileURLWithPath: worktreePath, isDirectory: true) }
        if let projectPathForProjectFeatures { return URL(fileURLWithPath: projectPathForProjectFeatures, isDirectory: true) }
        return Self.generalChatScratchRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var legacyNoProjectLaunchWorkingDirectory: URL {
        Self.legacyNoProjectScratchRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// True when this session is a 1:1 chat with a specific agent (`kind == .agent`
    /// and `agentName` resolved). The runner launches Pi with the agent's system
    /// prompt + tool allowlist + agent-defined extensions, with no
    /// `managed_subagent` bridge above it.
    var isAgentBound: Bool { kind == .agent && (agentName?.isEmpty == false) }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, projectPath, projectName, repository, issueNumber, issueURL, piSessionFile, ownedPiSessionFiles, piSessionId
        case model, modelProvider, modelOverrideID, modelOverrideProvider, commandInvocations, thinkingLevel, launchCommand, branchName, worktreePath, sourceBranch
        case status, lastError, lastSummary, needsAttention, lastNotificationAt, lastUserMessageAt
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens, toolCalls, toolResults, contextTokens, contextWindow, contextPercent, contextBreakdown, cost, costBreakdown
        case finalSystemPrompt, finalSystemPromptCapturedAt
        case pendingSteeringMessages, pendingFollowUpMessages, subagentsEnabled, memoryEnabled, agentSelection, agentLaunchOverrides, injectedExtensions, agentName, noProjectMode, isCompacting, isTitleUserEdited, pinnedAt, createdAt, updatedAt
        case forkedFromSessionID, forkedFromParentTitle, forkedFromUserMessageText, forkedFromTranscriptSnapshot
        case recalledMemoryPrompt, recalledMemoryIDs, memoryRecallCompleted
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
        sourceBranch: String? = nil,
        status: PiAgentRunStatus,
        lastError: String?,
        lastSummary: String?,
        needsAttention: Bool,
        lastNotificationAt: Date?,
        lastUserMessageAt: Date? = nil,
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
        costBreakdown: PiAgentUsageCostBreakdown? = nil,
        finalSystemPrompt: String? = nil,
        finalSystemPromptCapturedAt: Date? = nil,
        pendingSteeringMessages: [String],
        pendingFollowUpMessages: [String],
        subagentsEnabled: Bool,
        memoryEnabled: Bool = true,
        agentSelection: Set<String>? = nil,
        agentLaunchOverrides: [String: PiAgentSessionAgentLaunchOverride]? = nil,
        injectedExtensions: [String]? = nil,
        agentName: String? = nil,
        noProjectMode: PiAgentNoProjectMode? = nil,
        isCompacting: Bool = false,
        isTitleUserEdited: Bool = false,
        forkedFromSessionID: UUID? = nil,
        forkedFromParentTitle: String? = nil,
        forkedFromUserMessageText: String? = nil,
        forkedFromTranscriptSnapshot: String? = nil,
        recalledMemoryPrompt: String? = nil,
        recalledMemoryIDs: [String]? = nil,
        memoryRecallCompleted: Bool = false,
        pinnedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        ownedPiSessionFiles: [String]? = nil
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
        self.ownedPiSessionFiles = Array(Set((ownedPiSessionFiles ?? []) + [piSessionFile].compactMap { $0 })).sorted()
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
        self.sourceBranch = sourceBranch
        self.status = status
        self.lastError = lastError
        self.lastSummary = lastSummary
        self.needsAttention = needsAttention
        self.lastNotificationAt = lastNotificationAt
        self.lastUserMessageAt = lastUserMessageAt
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
        self.costBreakdown = costBreakdown
        self.finalSystemPrompt = finalSystemPrompt
        self.finalSystemPromptCapturedAt = finalSystemPromptCapturedAt
        self.pendingSteeringMessages = pendingSteeringMessages
        self.pendingFollowUpMessages = pendingFollowUpMessages
        self.subagentsEnabled = subagentsEnabled
        self.memoryEnabled = memoryEnabled
        self.agentSelection = agentSelection
        self.agentLaunchOverrides = agentLaunchOverrides
        self.injectedExtensions = injectedExtensions
        self.agentName = agentName
        self.noProjectMode = noProjectMode
        self.isCompacting = isCompacting
        self.isTitleUserEdited = isTitleUserEdited
        self.forkedFromSessionID = forkedFromSessionID
        self.forkedFromParentTitle = forkedFromParentTitle
        self.forkedFromUserMessageText = forkedFromUserMessageText
        self.forkedFromTranscriptSnapshot = forkedFromTranscriptSnapshot
        self.recalledMemoryPrompt = recalledMemoryPrompt
        self.recalledMemoryIDs = recalledMemoryIDs
        self.memoryRecallCompleted = memoryRecallCompleted
        self.pinnedAt = pinnedAt
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
            sourceBranch: try container.decodeIfPresent(String.self, forKey: .sourceBranch),
            status: try container.decode(PiAgentRunStatus.self, forKey: .status),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            lastSummary: try container.decodeIfPresent(String.self, forKey: .lastSummary),
            needsAttention: try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
            lastNotificationAt: try container.decodeIfPresent(Date.self, forKey: .lastNotificationAt),
            lastUserMessageAt: try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt),
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
            costBreakdown: try container.decodeIfPresent(PiAgentUsageCostBreakdown.self, forKey: .costBreakdown),
            finalSystemPrompt: try container.decodeIfPresent(String.self, forKey: .finalSystemPrompt),
            finalSystemPromptCapturedAt: try container.decodeIfPresent(Date.self, forKey: .finalSystemPromptCapturedAt),
            pendingSteeringMessages: try container.decodeIfPresent([String].self, forKey: .pendingSteeringMessages) ?? [],
            pendingFollowUpMessages: try container.decodeIfPresent([String].self, forKey: .pendingFollowUpMessages) ?? [],
            subagentsEnabled: try container.decodeIfPresent(Bool.self, forKey: .subagentsEnabled) ?? true,
            memoryEnabled: try container.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true,
            agentSelection: try container.decodeIfPresent(Set<String>.self, forKey: .agentSelection),
            agentLaunchOverrides: try container.decodeIfPresent([String: PiAgentSessionAgentLaunchOverride].self, forKey: .agentLaunchOverrides),
            injectedExtensions: try container.decodeIfPresent([String].self, forKey: .injectedExtensions),
            agentName: try container.decodeIfPresent(String.self, forKey: .agentName),
            noProjectMode: try container.decodeIfPresent(PiAgentNoProjectMode.self, forKey: .noProjectMode),
            isCompacting: try container.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false,
            isTitleUserEdited: try container.decodeIfPresent(Bool.self, forKey: .isTitleUserEdited) ?? false,
            forkedFromSessionID: try container.decodeIfPresent(UUID.self, forKey: .forkedFromSessionID),
            forkedFromParentTitle: try container.decodeIfPresent(String.self, forKey: .forkedFromParentTitle),
            forkedFromUserMessageText: try container.decodeIfPresent(String.self, forKey: .forkedFromUserMessageText),
            forkedFromTranscriptSnapshot: try container.decodeIfPresent(String.self, forKey: .forkedFromTranscriptSnapshot),
            recalledMemoryPrompt: try container.decodeIfPresent(String.self, forKey: .recalledMemoryPrompt),
            recalledMemoryIDs: try container.decodeIfPresent([String].self, forKey: .recalledMemoryIDs),
            memoryRecallCompleted: try container.decodeIfPresent(Bool.self, forKey: .memoryRecallCompleted) ?? false,
            pinnedAt: try container.decodeIfPresent(Date.self, forKey: .pinnedAt),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            ownedPiSessionFiles: try container.decodeIfPresent([String].self, forKey: .ownedPiSessionFiles)
        )
    }
}

extension PiAgentSessionRecord {
    /// Canonical session-list ordering, shared by the compact recent strip and
    /// the store's persistent order. Keep this comparator on the collapsed strip
    /// and the on-disk session list so a streaming pulse (bumping `updatedAt`
    /// within the same day) does NOT reshuffle the compact strip's rows.
    ///
    /// `updatedAt` is compared at `.day` granularity so a session that streams a
    /// response (bumping `updatedAt` within the same day) does NOT reshuffle to
    /// the top of the list — only a calendar-day change reorders. Within a day,
    /// sessions settle by `createdAt` DESC then `id` for a stable tiebreak.
    static func sessionListPrecedes(_ lhs: PiAgentSessionRecord, _ rhs: PiAgentSessionRecord, calendar: Calendar = .current) -> Bool {
        let updatedDayComparison = calendar.compare(lhs.updatedAt, to: rhs.updatedAt, toGranularity: .day)
        if updatedDayComparison != .orderedSame { return updatedDayComparison == .orderedDescending }

        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Strict exact-precision ordering used by the expanded/full coding-agent
    /// sidebar: sort by exact `updatedAt` DESC, then `createdAt` DESC, then `id`
    /// ASC. Within-day activity promotes a session to the top of its project
    /// group, so the most-recently-touched chat leads the expanded list. The
    /// compact strip keeps the day-granular `sessionListPrecedes` for stability.
    ///
    /// Streaming-induced reshuffling of the expanded list is suppressed by the
    /// panel's hybrid freeze (see `CodingAgentExpandedPanel`), not by this
    /// comparator; the comparator merely defines the natural top-of-list winner
    /// once the freeze releases.
    static func sessionListPrecedesExact(_ lhs: PiAgentSessionRecord, _ rhs: PiAgentSessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
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
    /// Pi is being relaunched because the user changed the model and/or
    /// thinking level. `summary` is the human-readable description shown in the
    /// processing bar (e.g. "thinking level to off", "model to opencode-go/kimi-k2.6").
    case applyingConfigurationChange(summary: String)
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

    func nativeAskResponseDisplayText(from value: String) -> String? {
        guard responseFormat == .nativeAsk,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return nil }

        switch kind {
        case "freeform":
            guard allowsFreeform || method == .input || method == .editor,
                  let text = object["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case "selection":
            guard method == .select || method == .multiSelect,
                  let selections = object["selections"] as? [String] else { return nil }
            let trimmedSelections = selections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !trimmedSelections.isEmpty,
                  trimmedSelections.allSatisfy({ !$0.isEmpty && options.contains($0) }),
                  method == .multiSelect || trimmedSelections.count == 1 else { return nil }

            var displayText = trimmedSelections.joined(separator: "\n")
            if let commentValue = object["comment"] {
                guard let comment = commentValue as? String else { return nil }
                let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedComment.isEmpty {
                    displayText += "\n\nComment: \(trimmedComment)"
                }
            }
            return displayText
        default:
            return nil
        }
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

struct PiAgentTranscriptImageReference: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var mimeType: String?
    /// Session-owned local file path for the materialized image. Nil means this
    /// is a persisted remote placeholder that has not been downloaded yet.
    var localPath: String?
    var source: String?
    var remoteURL: String?

    var isRemotePlaceholder: Bool { localPath == nil && remoteURL != nil }

    init(id: UUID = UUID(), name: String, mimeType: String? = nil, localPath: String?, source: String? = nil, remoteURL: String? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.localPath = localPath
        self.source = source
        self.remoteURL = remoteURL
    }
}

/// An ordered MCP call result. Images are materialized in the parent session's
/// transcript-image directory; the base64 received from Pi is deliberately never
/// retained in this model or in the persisted RPC payload.
enum PiAgentMCPResultBlock: Codable, Hashable, Sendable {
    case text(String)
    case image(PiAgentTranscriptImageReference)
    case diagnostic(String)

    private enum CodingKeys: String, CodingKey { case type, text, image, message }
    private enum Kind: String, Codable { case text, image, diagnostic }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .image: self = .image(try container.decode(PiAgentTranscriptImageReference.self, forKey: .image))
        case .diagnostic: self = .diagnostic(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .type); try container.encode(text, forKey: .text)
        case let .image(image):
            try container.encode(Kind.image, forKey: .type); try container.encode(image, forKey: .image)
        case let .diagnostic(message):
            try container.encode(Kind.diagnostic, forKey: .type); try container.encode(message, forKey: .message)
        }
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
    var imageReferences: [PiAgentTranscriptImageReference]
    /// Present only for MCP call results created by newer clients. Nil preserves
    /// historical text-only cards and distinguishes them from an empty result.
    var mcpResultBlocks: [PiAgentMCPResultBlock]?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case role
        case title
        case text
        case rawJSON
        case timestamp
        case imageReferences
        case mcpResultBlocks
    }

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: PiAgentTranscriptRole,
        title: String,
        text: String,
        rawJSON: String? = nil,
        timestamp: Date = Date(),
        imageReferences: [PiAgentTranscriptImageReference] = [],
        mcpResultBlocks: [PiAgentMCPResultBlock]? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.title = title
        self.text = text
        self.rawJSON = rawJSON
        self.timestamp = timestamp
        self.imageReferences = imageReferences
        self.mcpResultBlocks = mcpResultBlocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        role = try container.decode(PiAgentTranscriptRole.self, forKey: .role)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        rawJSON = try container.decodeIfPresent(String.self, forKey: .rawJSON)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        imageReferences = try container.decodeIfPresent([PiAgentTranscriptImageReference].self, forKey: .imageReferences) ?? []
        mcpResultBlocks = try container.decodeIfPresent([PiAgentMCPResultBlock].self, forKey: .mcpResultBlocks)
    }
}

extension PiAgentTranscriptEntry {
    static let nativeAskResponseTitle = "Ask User Response"

    var isNativeAskResponse: Bool {
        role == .user && title == Self.nativeAskResponseTitle
    }

    /// A user message that exists in Pi's provider-backed conversation history.
    /// Synthetic ask-user answers are transcript-only and must not affect fork indexes.
    var isProviderBackedUserMessage: Bool {
        role == .user && !isNativeAskResponse
    }

    /// Includes legacy/general references and ordered MCP image blocks. Keeping this
    /// centralized makes retention cleanup safe when an image is shared by entries.
    var allTranscriptImageReferences: [PiAgentTranscriptImageReference] {
        imageReferences + (mcpResultBlocks ?? []).compactMap { block in
            guard case let .image(reference) = block else { return nil }
            return reference
        }
    }

    /// A per-tool failure (titled `Tool: <name>`). Frequent and tied to a tool
    /// call, so it renders as a compact grouped row and honors the Errors toggle.
    var isToolError: Bool { role == .error && title.hasPrefix("Tool: ") }

    /// A fatal turn/model/provider error — Pi aborted the turn and produced no
    /// output. Rendered as a prominent card and always shown (even when the
    /// Errors toggle is off) so a turn that did nothing is never silent.
    var isModelError: Bool { role == .error && !isToolError }
}

/// Single source of truth for the four divider-style git events that the
/// toolbar appends to a session transcript. Keeps `isDividerStatus`, the
/// transcript filter, and the divider icon table in sync via one type.
enum PiAgentGitEventKind: CaseIterable {
    case commit
    case commitAndPush
    case push
    case merge

    var transcriptTitle: String {
        switch self {
        case .commit:        return "Commit Completed"
        case .commitAndPush: return "Commit & Push Completed"
        case .push:          return "Push Completed"
        case .merge:         return "Merge Completed"
        }
    }

    var icon: String {
        switch self {
        case .commit:                   return "checkmark.circle"
        case .push, .commitAndPush:     return "arrow.up.circle"
        case .merge:                    return "arrow.triangle.merge"
        }
    }

    static func from(title: String) -> PiAgentGitEventKind? {
        allCases.first { $0.transcriptTitle == title }
    }
}

struct PiAgentSessionGitActivity: Equatable {
    var lastCommit: Date?
    var lastPush: Date?
    var lastMerge: Date?

    var hasCommit: Bool { lastCommit != nil }
    var hasPush:   Bool { lastPush != nil }
    var hasMerge:  Bool { lastMerge != nil }

    static let none = PiAgentSessionGitActivity()
}

/// Hides the internal `agent-deck/` ref-namespace prefix from worktree branch
/// names in the UI. The prefix is still part of the actual git branch — it
/// keeps tool-managed branches from colliding with user branches inside the
/// same repo — but it's noise when shown next to an Agent Deck session.
func piAgentSessionDisplayBranchName(_ branch: String) -> String {
    let prefix = "agent-deck/"
    if branch.hasPrefix(prefix) {
        return String(branch.dropFirst(prefix.count))
    }
    return branch
}

func piAgentSessionGitActivity(from transcript: [PiAgentTranscriptEntry]) -> PiAgentSessionGitActivity {
    var out = PiAgentSessionGitActivity()
    for entry in transcript where entry.role == .status {
        guard let kind = PiAgentGitEventKind.from(title: entry.title) else { continue }
        let ts = entry.timestamp
        switch kind {
        case .commit:
            if (out.lastCommit ?? .distantPast) < ts { out.lastCommit = ts }
        case .commitAndPush:
            if (out.lastCommit ?? .distantPast) < ts { out.lastCommit = ts }
            if (out.lastPush  ?? .distantPast) < ts { out.lastPush  = ts }
        case .push:
            if (out.lastPush  ?? .distantPast) < ts { out.lastPush  = ts }
        case .merge:
            if (out.lastMerge ?? .distantPast) < ts { out.lastMerge = ts }
        }
    }
    return out
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
    /// Extension UI `notify` severity (`info` | `warning` | `error`).
    let notifyType: String?
    /// Extension UI `setStatus` key / text (fire-and-forget footer status).
    let statusKey: String?
    let statusText: String?
    /// Extension UI `setWidget` key / lines (fire-and-forget chrome widget).
    let widgetKey: String?
    let widgetLines: JSONValue?
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

    var flexibleNumber: Double? {
        if let numberValue { return numberValue }
        if case let .string(value) = self { return Double(value) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
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

    /// Bridges a `JSONSerialization` result (a tree of `String`/`NSNumber`/
    /// `Bool`/`NSNull`/`[Any]`/`[String: Any]`) into a strongly-typed
    /// `JSONValue` tree. Returns nil for unsupported types (e.g. `Date`).
    static func fromFoundation(_ value: Any) -> JSONValue? {
        if value is NSNull { return .null }
        if let bool = value as? Bool, type(of: value) is Bool.Type || (value as? NSNumber)?.objCType.pointee == 99 /* 'c' for char/Bool */ {
            return .bool(bool)
        }
        if let number = value as? NSNumber {
            // NSNumber treats Bool as a special case; distinguish via objCType.
            if number.objCType.pointee == 99 { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = value as? String { return .string(string) }
        if let array = value as? [Any] {
            return .array(array.compactMap { JSONValue.fromFoundation($0) })
        }
        if let dict = value as? [String: Any] {
            return .object(dict.compactMapValues { JSONValue.fromFoundation($0) })
        }
        return nil
    }
}
