import Foundation

enum AgentMemoryScope: String, Codable, CaseIterable, Identifiable {
    case global
    case project
    case session
    case subagent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return "Global"
        case .project: return "Project"
        case .session: return "Session"
        case .subagent: return "Subagent"
        }
    }
}

enum AgentMemoryKind: String, Codable, CaseIterable, Identifiable {
    case context
    case decision
    case observation
    case runbook
    case failure
    case sessionSummary
    case subagentFinding
    case preference

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .context: return "Context"
        case .decision: return "Decision"
        case .observation: return "Observation"
        case .runbook: return "Runbook"
        case .failure: return "Failure"
        case .sessionSummary: return "Session Summary"
        case .subagentFinding: return "Subagent Finding"
        case .preference: return "Preference"
        }
    }
}

enum AgentMemoryStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case active
    case pinned
    case stale
    case archived
    case rejected

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .active: return "Active"
        case .pinned: return "Pinned"
        case .stale: return "Stale"
        case .archived: return "Archived"
        case .rejected: return "Rejected"
        }
    }

    var isInjectable: Bool {
        self == .active || self == .pinned
    }
}

struct AgentMemoryRecord: Identifiable, Codable, Hashable {
    var id: String
    var kind: AgentMemoryKind
    var scope: AgentMemoryScope
    var status: AgentMemoryStatus
    var title: String
    var summary: String
    var filePath: String
    var projectPath: String?
    var sourceSessionID: UUID?
    var sourceRunID: UUID?
    var sourceAgentName: String?
    var proposalReason: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var tags: [String]

    var isPending: Bool { status == .pending }
    var isInjectable: Bool { status.isInjectable }
}

struct AgentMemoryDocument: Hashable {
    var record: AgentMemoryRecord
    var body: String
}

struct AgentMemoryRetrieval: Hashable {
    var records: [AgentMemoryRecord]
    var prompt: String
}

enum AgentMemoryEventKind: String, Codable, Hashable {
    case recalled
    case stored
    case edited
    case proposed
    case rejected
    case archived
    case stale
    case blocked

    var displayTitle: String {
        switch self {
        case .recalled: return "Memory Recalled"
        case .stored: return "Memory Stored"
        case .edited: return "Memory Edited"
        case .proposed: return "Memory Proposed"
        case .rejected: return "Memory Rejected"
        case .archived: return "Memory Archived"
        case .stale: return "Memory Marked Stale"
        case .blocked: return "Memory Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .recalled: return "brain"
        case .stored: return "tray.and.arrow.down"
        case .edited: return "pencil"
        case .proposed: return "text.badge.plus"
        case .rejected: return "xmark.circle"
        case .archived: return "archivebox"
        case .stale: return "clock.badge.exclamationmark"
        case .blocked: return "exclamationmark.shield"
        }
    }
}

struct AgentMemoryTranscriptEvent: Codable, Hashable {
    var type: String
    var event: AgentMemoryEventKind
    var memoryIDs: [String]
    var scope: AgentMemoryScope?
    var title: String
    var summary: String

    static let rawType = "agent_deck_memory_event"
}

struct AgentMemoryProposalBridgeRequest: Codable, Hashable {
    var title: String
    var summary: String
    var body: String
    var kind: AgentMemoryKind?
    var scope: AgentMemoryScope?
    var tags: [String]?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case body
        case kind = "kindHint"
        case scope
        case tags
        case reason
    }
}

struct AgentMemoryStaleBridgeRequest: Codable, Hashable {
    var memoryIDs: [String]?
    var query: String?
    var reason: String?
}
