import Combine
import Foundation

@MainActor
final class PiAgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [PiAgentSessionRecord] = []
    @Published private(set) var transcriptsBySessionID: [UUID: [PiAgentTranscriptEntry]] = [:]
    @Published private(set) var transcriptRevisionsBySessionID: [UUID: Int] = [:]
    @Published private(set) var uiRequestsBySessionID: [UUID: PiAgentUIRequest] = [:]
    @Published private(set) var subagentRunsBySessionID: [UUID: [PiSubagentRunRecord]] = [:]
    @Published private(set) var subagentTranscriptsByRunID: [UUID: [PiAgentTranscriptEntry]] = [:]
    @Published private(set) var supervisorRequestsBySessionID: [UUID: [PiSubagentSupervisorRequest]] = [:]
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?
    var newSessionSubagentsEnabled = true

    private let maxTranscriptEntriesPerSession = 500
    private let fileURL: URL
    private var pendingSaveTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport.appendingPathComponent("Pi Manager", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("agent-sessions.json")
        load()
    }

    var selectedSession: PiAgentSessionRecord? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedTranscript: [PiAgentTranscriptEntry] {
        guard let session = selectedSession else { return [] }
        return transcriptsBySessionID[session.id] ?? []
    }

    var selectedTranscriptRevision: Int {
        guard let session = selectedSession else { return 0 }
        return transcriptRevisionsBySessionID[session.id] ?? 0
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
            subagentsEnabled: newSessionSubagentsEnabled,
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(record, at: 0)
        sortSessions()
        transcriptsBySessionID[record.id] = []
        transcriptRevisionsBySessionID[record.id] = 0
        uiRequestsBySessionID[record.id] = nil
        subagentRunsBySessionID[record.id] = []
        supervisorRequestsBySessionID[record.id] = []
        selectedSessionID = record.id
        save()
        return record
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        save()
    }

    func clearSelection() {
        selectedSessionID = nil
        save()
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
        updateSession(id, bumpUpdatedAt: false) {
            $0.title = trimmedTitle
            $0.isTitleUserEdited = true
        }
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

    func subagentRuns(for sessionID: UUID) -> [PiSubagentRunRecord] {
        subagentRunsBySessionID[sessionID] ?? []
    }

    func subagentTranscript(for runID: UUID) -> [PiAgentTranscriptEntry] {
        subagentTranscriptsByRunID[runID] ?? []
    }

    func supervisorRequests(for sessionID: UUID) -> [PiSubagentSupervisorRequest] {
        supervisorRequestsBySessionID[sessionID] ?? []
    }

    var selectedSupervisorRequests: [PiSubagentSupervisorRequest] {
        guard let session = selectedSession else { return [] }
        return supervisorRequests(for: session.id)
    }

    func upsertSubagentRun(_ run: PiSubagentRunRecord) {
        var runs = subagentRunsBySessionID[run.parentSessionID] ?? []
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        subagentRunsBySessionID[run.parentSessionID] = runs.sorted { $0.updatedAt > $1.updatedAt }
        touchSession(run.parentSessionID, bumpUpdatedAt: true)
    }

    func updateSubagentRun(_ runID: UUID, parentSessionID: UUID, mutate: (inout PiSubagentRunRecord) -> Void) {
        var runs = subagentRunsBySessionID[parentSessionID] ?? []
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        mutate(&runs[index])
        runs[index].updatedAt = Date()
        subagentRunsBySessionID[parentSessionID] = runs.sorted { $0.updatedAt > $1.updatedAt }
        touchSession(parentSessionID, bumpUpdatedAt: true)
    }

    func appendSubagentTranscript(_ entry: PiAgentTranscriptEntry, runID: UUID, parentSessionID: UUID) {
        var entries = subagentTranscriptsByRunID[runID] ?? []
        entries.append(entry)
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
        subagentTranscriptsByRunID[runID] = entries
        touchSession(parentSessionID, bumpUpdatedAt: false)
    }

    func upsertSubagentTranscript(_ entry: PiAgentTranscriptEntry, runID: UUID, parentSessionID: UUID, before beforeEntryID: UUID? = nil) {
        var entries = subagentTranscriptsByRunID[runID] ?? []
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else if let beforeEntryID, let beforeIndex = entries.firstIndex(where: { $0.id == beforeEntryID }) {
            entries.insert(entry, at: beforeIndex)
        } else {
            entries.append(entry)
        }
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
        subagentTranscriptsByRunID[runID] = entries
        touchSession(parentSessionID, bumpUpdatedAt: false)
    }

    func upsertSupervisorRequest(_ request: PiSubagentSupervisorRequest) {
        var requests = supervisorRequestsBySessionID[request.parentSessionID] ?? []
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.insert(request, at: 0)
        }
        supervisorRequestsBySessionID[request.parentSessionID] = requests.sorted { $0.updatedAt > $1.updatedAt }
        touchSession(request.parentSessionID, bumpUpdatedAt: true)
    }

    func updateSupervisorRequest(_ id: String, parentSessionID: UUID, mutate: (inout PiSubagentSupervisorRequest) -> Void) {
        var requests = supervisorRequestsBySessionID[parentSessionID] ?? []
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        mutate(&requests[index])
        requests[index].updatedAt = Date()
        supervisorRequestsBySessionID[parentSessionID] = requests.sorted { $0.updatedAt > $1.updatedAt }
        touchSession(parentSessionID, bumpUpdatedAt: true)
    }

    func append(_ entry: PiAgentTranscriptEntry) {
        var entries = transcriptsBySessionID[entry.sessionID] ?? []
        entries.append(entry)
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
        transcriptsBySessionID[entry.sessionID] = entries
        bumpTranscriptRevision(entry.sessionID)
        touchSession(entry.sessionID, bumpUpdatedAt: true)
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
        bumpTranscriptRevision(entry.sessionID)
        if isNewEntry {
            touchSession(entry.sessionID, bumpUpdatedAt: true)
        } else {
            save()
        }
    }

    func updateEntry(_ entryID: UUID, in sessionID: UUID, mutate: (inout PiAgentTranscriptEntry) -> Void) {
        var entries = transcriptsBySessionID[sessionID] ?? []
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        mutate(&entries[index])
        transcriptsBySessionID[sessionID] = entries
        bumpTranscriptRevision(sessionID)
        save()
    }

    func deleteSession(_ sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        transcriptsBySessionID[sessionID] = nil
        transcriptRevisionsBySessionID[sessionID] = nil
        let runIDs = subagentRunsBySessionID[sessionID]?.map(\.id) ?? []
        for runID in runIDs {
            subagentTranscriptsByRunID[runID] = nil
        }
        subagentRunsBySessionID[sessionID] = nil
        supervisorRequestsBySessionID[sessionID] = nil
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.first?.id
        }
        save()
    }

    func clearTranscript(for sessionID: UUID) {
        transcriptsBySessionID[sessionID] = []
        bumpTranscriptRevision(sessionID)
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
                session.isCompacting = false
                return session
            }
            sortSessions()
            transcriptsBySessionID = Dictionary(uniqueKeysWithValues: persisted.transcripts.map { ($0.sessionID, $0.entries) })
            transcriptRevisionsBySessionID = Dictionary(uniqueKeysWithValues: transcriptsBySessionID.map { ($0.key, 0) })
            subagentRunsBySessionID = Dictionary(uniqueKeysWithValues: (persisted.subagentRuns ?? []).map { persistedRuns in
                let recovered = persistedRuns.runs.map { run -> PiSubagentRunRecord in
                    var run = run
                    if run.status.isActive {
                        let completedAt = Date()
                        run.status = .disconnected
                        run.error = run.error ?? "Disconnected because Pi Manager was restarted."
                        run.updatedAt = completedAt
                        run.completedAt = run.completedAt ?? completedAt
                        run.durationMs = run.durationMs ?? max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
                        if var child = run.child {
                            child.status = .disconnected
                            child.error = child.error ?? run.error
                            child.updatedAt = completedAt
                            child.completedAt = child.completedAt ?? completedAt
                            child.durationMs = child.durationMs ?? max(0, Int((completedAt.timeIntervalSince(child.createdAt) * 1000).rounded()))
                            run.child = child
                        }
                        if var children = run.children {
                            for index in children.indices where children[index].status.isActive {
                                children[index].status = .disconnected
                                children[index].error = children[index].error ?? run.error
                                children[index].updatedAt = completedAt
                                children[index].completedAt = children[index].completedAt ?? completedAt
                                children[index].durationMs = children[index].durationMs ?? max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
                            }
                            run.children = children
                        }
                    }
                    return run
                }
                return (persistedRuns.sessionID, recovered)
            })
            subagentTranscriptsByRunID = Dictionary(uniqueKeysWithValues: (persisted.subagentTranscripts ?? []).map { ($0.runID, $0.entries) })
            let subagentStatusesByRunID = Dictionary(uniqueKeysWithValues: subagentRunsBySessionID.values.flatMap { runs in
                runs.map { ($0.id, $0.status) }
            })
            supervisorRequestsBySessionID = Dictionary(uniqueKeysWithValues: (persisted.supervisorRequests ?? []).map { persistedRequests in
                let recovered = persistedRequests.requests.map { request -> PiSubagentSupervisorRequest in
                    var request = request
                    if request.status == .pending, let runStatus = subagentStatusesByRunID[request.runID], !runStatus.isActive {
                        request.status = .cancelled
                        request.response = request.response ?? "Cancelled because the child subagent is no longer connected."
                        request.updatedAt = Date()
                    }
                    return request
                }
                return (persistedRequests.sessionID, recovered)
            })
            selectedSessionID = persisted.selectedSessionID ?? sessions.first?.id
        } catch {
            lastError = "Could not load Pi Agent sessions: \(error.localizedDescription)"
            sessions = []
            transcriptsBySessionID = [:]
            selectedSessionID = nil
        }
    }

    private func bumpTranscriptRevision(_ sessionID: UUID) {
        transcriptRevisionsBySessionID[sessionID, default: 0] += 1
    }

    private func sortSessions() {
        sessions.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func touchSession(_ id: UUID, bumpUpdatedAt: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            save()
            return
        }
        if bumpUpdatedAt {
            sessions[index].updatedAt = Date()
            sortSessions()
        }
        save()
    }

    private func save() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.saveNow()
            }
        }
    }

    private func saveNow() {
        do {
            let persisted = PersistedState(
                sessions: sessions,
                transcripts: transcriptsBySessionID.map { PersistedTranscript(sessionID: $0.key, entries: $0.value) },
                selectedSessionID: selectedSessionID,
                subagentRuns: subagentRunsBySessionID.map { PersistedSubagentRuns(sessionID: $0.key, runs: $0.value) },
                subagentTranscripts: subagentTranscriptsByRunID.map { PersistedSubagentTranscript(runID: $0.key, entries: $0.value) },
                supervisorRequests: supervisorRequestsBySessionID.map { PersistedSupervisorRequests(sessionID: $0.key, requests: $0.value) }
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
    var subagentRuns: [PersistedSubagentRuns]?
    var subagentTranscripts: [PersistedSubagentTranscript]?
    var supervisorRequests: [PersistedSupervisorRequests]?
}

private struct PersistedTranscript: Codable {
    var sessionID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private struct PersistedSubagentRuns: Codable {
    var sessionID: UUID
    var runs: [PiSubagentRunRecord]
}

private struct PersistedSubagentTranscript: Codable {
    var runID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private struct PersistedSupervisorRequests: Codable {
    var sessionID: UUID
    var requests: [PiSubagentSupervisorRequest]
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
