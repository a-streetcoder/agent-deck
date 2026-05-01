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

struct PiAgentImageAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var mimeType: String
    var data: String
    var sizeBytes: Int

    nonisolated init(id: UUID = UUID(), name: String, mimeType: String, data: String, sizeBytes: Int) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.sizeBytes = sizeBytes
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
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        if let issueNumber {
            return "#\(issueNumber) \(title)"
        }
        return title
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

struct PiAgentRPCEvent: Decodable {
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
}

enum JSONValue: Codable, Hashable {
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
