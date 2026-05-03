import Combine
import Foundation

@MainActor
final class PiAgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [PiAgentSessionRecord] = []
    @Published private(set) var transcriptsBySessionID: [UUID: [PiAgentTranscriptEntry]] = [:]
    @Published private(set) var uiRequestsBySessionID: [UUID: PiAgentUIRequest] = [:]
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?

    private let maxTranscriptEntriesPerSession = 500
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport.appendingPathComponent("Pi Manager", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("agent-sessions.json")
        load()
    }

    var selectedSession: PiAgentSessionRecord? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedTranscript: [PiAgentTranscriptEntry] {
        guard let session = selectedSession else { return [] }
        return transcriptsBySessionID[session.id] ?? []
    }

    var selectedUIRequest: PiAgentUIRequest? {
        guard let session = selectedSession else { return nil }
        return uiRequestsBySessionID[session.id]
    }

    @discardableResult
    func createSession(kind: PiAgentSessionKind, title: String, project: DiscoveredProject, repository: String?, issueNumber: Int? = nil, issueURL: URL? = nil, model: String? = nil) -> PiAgentSessionRecord {
        let now = Date()
        let record = PiAgentSessionRecord(
            id: UUID(),
            kind: kind,
            title: title.isEmpty ? "New Agent Session" : title,
            projectPath: project.path,
            projectName: project.name,
            repository: repository,
            issueNumber: issueNumber,
            issueURL: issueURL,
            piSessionFile: nil,
            piSessionId: nil,
            model: model,
            modelProvider: nil,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            availableModels: nil,
            thinkingLevel: nil,
            launchCommand: nil,
            branchName: nil,
            worktreePath: nil,
            status: .draft,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
            isPinned: false,
            lastNotificationAt: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: nil,
            toolCalls: nil,
            toolResults: nil,
            contextTokens: nil,
            contextWindow: nil,
            contextPercent: nil,
            cost: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(record, at: 0)
        sortSessions()
        transcriptsBySessionID[record.id] = []
        uiRequestsBySessionID[record.id] = nil
        selectedSessionID = record.id
        save()
        return record
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
    }

    func updateSession(_ id: UUID, bumpUpdatedAt: Bool = false, mutate: (inout PiAgentSessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[index])
        if bumpUpdatedAt {
            sessions[index].updatedAt = Date()
        }
        sortSessions()
        save()
    }

    func renameSession(_ id: UUID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        updateSession(id, bumpUpdatedAt: false) { $0.title = trimmedTitle }
    }

    func setPinned(_ id: UUID, isPinned: Bool) {
        updateSession(id, bumpUpdatedAt: false) { $0.isPinned = isPinned }
    }

    func togglePinned(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        setPinned(id, isPinned: !session.isPinned)
    }

    func setUIRequest(_ request: PiAgentUIRequest?) {
        guard let sessionID = request?.sessionID ?? selectedSessionID else { return }
        uiRequestsBySessionID[sessionID] = request
    }

    func clearUIRequest(sessionID: UUID, id: String? = nil) {
        guard let id else {
            uiRequestsBySessionID[sessionID] = nil
            return
        }
        if uiRequestsBySessionID[sessionID]?.id == id {
            uiRequestsBySessionID[sessionID] = nil
        }
    }

    func append(_ entry: PiAgentTranscriptEntry) {
        var entries = transcriptsBySessionID[entry.sessionID] ?? []
        entries.append(entry)
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
        transcriptsBySessionID[entry.sessionID] = entries
        updateSession(entry.sessionID, bumpUpdatedAt: true) { _ in }
    }

    func upsert(_ entry: PiAgentTranscriptEntry, before beforeEntryID: UUID? = nil) {
        var entries = transcriptsBySessionID[entry.sessionID] ?? []
        let isNewEntry: Bool
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            isNewEntry = false
        } else if let beforeEntryID, let beforeIndex = entries.firstIndex(where: { $0.id == beforeEntryID }) {
            entries.insert(entry, at: beforeIndex)
            isNewEntry = true
        } else {
            entries.append(entry)
            isNewEntry = true
        }
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
        transcriptsBySessionID[entry.sessionID] = entries
        updateSession(entry.sessionID, bumpUpdatedAt: isNewEntry) { _ in }
    }

    func updateEntry(_ entryID: UUID, in sessionID: UUID, mutate: (inout PiAgentTranscriptEntry) -> Void) {
        var entries = transcriptsBySessionID[sessionID] ?? []
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        mutate(&entries[index])
        transcriptsBySessionID[sessionID] = entries
        updateSession(sessionID, bumpUpdatedAt: false) { _ in }
    }

    func deleteSession(_ sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        transcriptsBySessionID[sessionID] = nil
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.first?.id
        }
        save()
    }

    func clearTranscript(for sessionID: UUID) {
        transcriptsBySessionID[sessionID] = []
        save()
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            let persisted = try JSONDecoder.piAgent.decode(PersistedState.self, from: data)
            sessions = persisted.sessions.map { session in
                var session = session
                if session.status.isActive {
                    session.status = .stopped
                    session.lastError = session.lastError ?? "Stopped because Pi Manager was restarted."
                }
                return session
            }
            sortSessions()
            transcriptsBySessionID = Dictionary(uniqueKeysWithValues: persisted.transcripts.map { ($0.sessionID, $0.entries) })
            selectedSessionID = persisted.selectedSessionID ?? sessions.first?.id
        } catch {
            lastError = "Could not load Pi Agent sessions: \(error.localizedDescription)"
            sessions = []
            transcriptsBySessionID = [:]
            selectedSessionID = nil
        }
    }

    private func sortSessions() {
        sessions.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func save() {
        do {
            let persisted = PersistedState(
                sessions: sessions,
                transcripts: transcriptsBySessionID.map { PersistedTranscript(sessionID: $0.key, entries: $0.value) },
                selectedSessionID: selectedSessionID
            )
            let data = try JSONEncoder.piAgent.encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Could not save Pi Agent sessions: \(error.localizedDescription)"
        }
    }
}

private struct PersistedState: Codable {
    var sessions: [PiAgentSessionRecord]
    var transcripts: [PersistedTranscript]
    var selectedSessionID: UUID?
}

private struct PersistedTranscript: Codable {
    var sessionID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private extension JSONEncoder {
    static var piAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var piAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
