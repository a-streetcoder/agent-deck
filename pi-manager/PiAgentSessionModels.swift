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
    var context: String?
}

struct PiManagedChainBridgeRequest: Codable, Hashable {
    var chain: String
    var task: String
    var worktree: Bool?
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

enum PiSubagentRunMode: String, Codable, Hashable {
    case single
    case chain
    case parallel
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

enum PiSubagentContextMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case agentDefault
    case fresh
    case fork

    var id: String { rawValue }

    init?(bridgeValue: String?) {
        guard let value = bridgeValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "fresh": self = .fresh
        case "fork": self = .fork
        case "agentdefault", "agent_default", "default": self = .agentDefault
        default: return nil
        }
    }
}

enum PiSubagentExpectedOutcome: String, Codable, Hashable, CaseIterable, Identifiable {
    case reportOnly
    case editFilesInWorktree
    case writeProjectFile
    case directProjectWrites

    var id: String { rawValue }

    var displayName: String {
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
    var requestedContext: PiSubagentContextMode?
    var resolvedContext: PiSubagentContextMode?
    var model: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
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
    var requestedContext: PiSubagentContextMode
    var resolvedContext: PiSubagentContextMode
    var model: String?
    var thinking: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var tools: [String]
    var skills: [String]
    var chainName: String?
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
            requestedContext: .agentDefault,
            resolvedContext: .fresh,
            model: nil,
            thinking: nil,
            expectedOutcome: nil,
            requestedOutputPath: nil,
            allowOverwrite: nil,
            tools: [],
            skills: [],
            chainName: nil,
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
    var supportsThinking: Bool?
    var supportedThinkingLevels: [String]?
    var supportsImages: Bool?

    var displayName: String { name?.isEmpty == false ? name! : id }
    var selectionID: String { "\(provider)/\(id)" }
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
    var availableModels: [PiAgentModelOption]?
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
    var cost: Double?
    var pendingSteeringMessages: [String]
    var pendingFollowUpMessages: [String]
    var subagentsEnabled: Bool
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
        case model, modelProvider, modelOverrideID, modelOverrideProvider, availableModels, thinkingLevel, launchCommand, branchName, worktreePath
        case status, lastError, lastSummary, needsAttention, isPinned, lastNotificationAt
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens, toolCalls, toolResults, contextTokens, contextWindow, contextPercent, cost
        case pendingSteeringMessages, pendingFollowUpMessages, subagentsEnabled, isCompacting, isTitleUserEdited, createdAt, updatedAt
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
        availableModels: [PiAgentModelOption]?,
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
        cost: Double?,
        pendingSteeringMessages: [String],
        pendingFollowUpMessages: [String],
        subagentsEnabled: Bool,
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
        self.availableModels = availableModels
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
        self.cost = cost
        self.pendingSteeringMessages = pendingSteeringMessages
        self.pendingFollowUpMessages = pendingFollowUpMessages
        self.subagentsEnabled = subagentsEnabled
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
            availableModels: try container.decodeIfPresent([PiAgentModelOption].self, forKey: .availableModels),
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
            cost: try container.decodeIfPresent(Double.self, forKey: .cost),
            pendingSteeringMessages: try container.decodeIfPresent([String].self, forKey: .pendingSteeringMessages) ?? [],
            pendingFollowUpMessages: try container.decodeIfPresent([String].self, forKey: .pendingFollowUpMessages) ?? [],
            subagentsEnabled: try container.decodeIfPresent(Bool.self, forKey: .subagentsEnabled) ?? true,
            isCompacting: try container.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false,
            isTitleUserEdited: try container.decodeIfPresent(Bool.self, forKey: .isTitleUserEdited) ?? false,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
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

struct PiAgentUIRequest: Identifiable, Hashable {
    enum Method: String, Hashable {
        case select
        case multiSelect
        case confirm
        case input
        case editor
    }

    let id: String
    let sessionID: UUID
    let method: Method
    let title: String
    let message: String?
    let options: [String]
    let placeholder: String?
    let prefill: String?
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

nonisolated struct PiAgentRPCEvent: Decodable {
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

nonisolated enum JSONValue: Codable, Hashable {
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
