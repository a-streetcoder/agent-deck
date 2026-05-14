import Foundation

enum AgentMemoryScope: String, Codable, CaseIterable, Identifiable {
    case project

    var id: String { rawValue }

    var displayName: String { "Project" }
}

enum AgentMemoryKind: String, Codable, CaseIterable, Identifiable {
    case context
    case decision
    case runbook
    case failure
    case preference

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .context: return "Context"
        case .decision: return "Decision"
        case .runbook: return "Runbook"
        case .failure: return "Failure"
        case .preference: return "Preference"
        }
    }

    var explanation: String {
        switch self {
        case .context: return "Durable facts about project structure, architecture, conventions, dependencies, or important files."
        case .decision: return "A choice that was made for the project, plus the rationale behind it."
        case .runbook: return "A repeatable procedure for doing project work, such as testing, releasing, deploying, debugging, or validating."
        case .failure: return "A known failed approach, recurring trap, bug pattern, or correction that should prevent repeated mistakes."
        case .preference: return "A project-specific user or team preference about style, tooling, commands, or workflow."
        }
    }
}

enum AgentMemoryStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case pinned
    case stale
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .pinned: return "Pinned"
        case .stale: return "Stale"
        case .archived: return "Archived"
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
    var writeReason: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var tags: [String]

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
    case archived
    case stale
    case blocked

    var displayTitle: String {
        switch self {
        case .recalled: return "Memory Recalled"
        case .stored: return "Memory Stored"
        case .edited: return "Memory Edited"
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

struct AgentMemoryWriteBridgeRequest: Codable, Hashable {
    var title: String
    var summary: String
    var body: String
    var kind: AgentMemoryKind?
    var tags: [String]?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case body
        case kind = "kindHint"
        case tags
        case reason
    }
}

struct AgentMemoryStaleBridgeRequest: Codable, Hashable {
    var memoryIDs: [String]?
    var query: String?
    var reason: String?
}
