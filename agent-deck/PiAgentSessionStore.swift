import Combine
import Foundation

@MainActor
final class PiAgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [PiAgentSessionRecord] = []
    @Published private(set) var transcriptsBySessionID: [UUID: [PiAgentTranscriptEntry]] = [:]
    @Published private(set) var transcriptLoadingSessionIDs: Set<UUID> = []
    @Published private(set) var transcriptRevisionsBySessionID: [UUID: Int] = [:]
    @Published private(set) var uiRequestsBySessionID: [UUID: PiAgentUIRequest] = [:]
    @Published private(set) var subagentRunsBySessionID: [UUID: [PiSubagentRunRecord]] = [:]
    @Published private(set) var subagentTranscriptsByRunID: [UUID: [PiAgentTranscriptEntry]] = [:]
    @Published private(set) var supervisorRequestsBySessionID: [UUID: [PiSubagentSupervisorRequest]] = [:]
    @Published private(set) var sessionPlansBySessionID: [UUID: PiSessionPlanRecord] = [:]
    @Published private(set) var sessionPlanEventsBySessionID: [UUID: [PiSessionPlanEventRecord]] = [:]
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?
    var newSessionSubagentsEnabled = true

    private var composerTextDraftsBySessionID: [UUID: String] = [:]
    private var composerImageDraftsBySessionID: [UUID: [PiAgentImageAttachment]] = [:]
    private var composerFileDraftsBySessionID: [UUID: [PiAgentFileAttachment]] = [:]
    private var composerFolderDraftsBySessionID: [UUID: [PiAgentFolderAttachment]] = [:]

    private let maxTranscriptEntriesPerSession = 500
    private let transcriptRevisionCoalesceNanoseconds: UInt64 = 66_000_000
    private let defaultSaveDebounceNanoseconds: UInt64 = 450_000_000
    private let structuralSaveDebounceNanoseconds: UInt64 = 50_000_000
    private let fileURL: URL
    private let transcriptsDirectoryURL: URL
    private let transcriptManifestURL: URL
    private let saveQueue = DispatchQueue(label: "agent-deck.pi-agent-session-store.save", qos: .utility)
    private var pendingSaveTask: Task<Void, Never>?
    private var saveSequence = 0
    private var pendingTranscriptRevisionSessionIDs: Set<UUID> = []
    private var pendingTranscriptRevisionTask: Task<Void, Never>?
    private var lazyTranscriptLoadingEnabled = true
    private var transcriptCacheLimit = 10
    private var persistedTranscriptSessionIDs: Set<UUID> = []
    private var persistedSubagentTranscriptRunIDs: Set<UUID> = []
    private var loadedTranscriptSessionOrder: [UUID] = []
    private var loadedSubagentTranscriptOrder: [UUID] = []
    private var transcriptLoadTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var subagentTranscriptLoadTasksByRunID: [UUID: Task<Void, Never>] = [:]

    init(fileManager: FileManager = .default) {
        let settings = AppSettingsStore.shared.settings
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("agent-sessions.json")
        transcriptsDirectoryURL = directory.appendingPathComponent("agent-session-transcripts", isDirectory: true)
        transcriptManifestURL = transcriptsDirectoryURL.appendingPathComponent("manifest.json")
        lazyTranscriptLoadingEnabled = settings.piAgentLazyTranscriptLoadingEnabled
        transcriptCacheLimit = max(settings.piAgentLoadedTranscriptCacheLimit, 1)
        try? fileManager.createDirectory(at: transcriptsDirectoryURL, withIntermediateDirectories: true)
        load()
    }

    init(fileURL: URL) {
        let settings = AppSettingsStore.shared.settings
        self.fileURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        transcriptsDirectoryURL = directory.appendingPathComponent("agent-session-transcripts", isDirectory: true)
        transcriptManifestURL = transcriptsDirectoryURL.appendingPathComponent("manifest.json")
        lazyTranscriptLoadingEnabled = settings.piAgentLazyTranscriptLoadingEnabled
        transcriptCacheLimit = max(settings.piAgentLoadedTranscriptCacheLimit, 1)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcriptsDirectoryURL, withIntermediateDirectories: true)
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

    var isSelectedTranscriptLoading: Bool {
        guard let selectedSessionID else { return false }
        return transcriptLoadingSessionIDs.contains(selectedSessionID)
    }

    var selectedUIRequest: PiAgentUIRequest? {
        guard let session = selectedSession else { return nil }
        return uiRequestsBySessionID[session.id]
    }

    func composerDraft(for sessionID: UUID) -> (text: String, images: [PiAgentImageAttachment], files: [PiAgentFileAttachment], folders: [PiAgentFolderAttachment]) {
        (
            composerTextDraftsBySessionID[sessionID] ?? "",
            composerImageDraftsBySessionID[sessionID] ?? [],
            composerFileDraftsBySessionID[sessionID] ?? [],
            composerFolderDraftsBySessionID[sessionID] ?? []
        )
    }

    func saveComposerDraft(text: String, images: [PiAgentImageAttachment], files: [PiAgentFileAttachment], folders: [PiAgentFolderAttachment], for sessionID: UUID) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty && folders.isEmpty {
            clearComposerDraft(for: sessionID)
        } else {
            composerTextDraftsBySessionID[sessionID] = text
            composerImageDraftsBySessionID[sessionID] = images
            composerFileDraftsBySessionID[sessionID] = files
            composerFolderDraftsBySessionID[sessionID] = folders
        }
    }

    func clearComposerDraft(for sessionID: UUID) {
        composerTextDraftsBySessionID.removeValue(forKey: sessionID)
        composerImageDraftsBySessionID.removeValue(forKey: sessionID)
        composerFileDraftsBySessionID.removeValue(forKey: sessionID)
        composerFolderDraftsBySessionID.removeValue(forKey: sessionID)
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
            finalSystemPrompt: nil,
            finalSystemPromptCapturedAt: nil,
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
        sessionPlansBySessionID[record.id] = nil
        sessionPlanEventsBySessionID[record.id] = []
        selectedSessionID = record.id
        markTranscriptSessionUsed(record.id)
        saveStructuralChange()
        return record
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        guard selectedSessionID != id else { return }
        selectedSessionID = id
        if lazyTranscriptLoadingEnabled {
            requestTranscriptLoad(for: id)
        } else {
            _ = transcript(for: id)
        }
        saveStructuralChange()
    }

    func configureTranscriptMemory(lazyLoadingEnabled: Bool, cacheLimit: Int) {
        lazyTranscriptLoadingEnabled = lazyLoadingEnabled
        transcriptCacheLimit = max(cacheLimit, 1)
        if lazyLoadingEnabled {
            evictTranscriptsIfNeeded()
        } else {
            cancelAllTranscriptLoadTasks()
            loadAllPersistedTranscriptsIntoMemory()
        }
    }

    func clearSelection() {
        selectedSessionID = nil
        saveStructuralChange()
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

    func applyGeneratedTitle(_ id: UUID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        updateSession(id, bumpUpdatedAt: false) { record in
            guard !record.isTitleUserEdited else { return }
            record.title = trimmedTitle
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
        loadSubagentTranscriptIfNeeded(runID)
        markSubagentTranscriptUsed(runID)
        evictTranscriptsIfNeeded(protectingSubagentRunID: runID)
        return subagentTranscriptsByRunID[runID] ?? []
    }

    func cachedSubagentTranscript(for runID: UUID) -> [PiAgentTranscriptEntry] {
        subagentTranscriptsByRunID[runID] ?? []
    }

    func transcript(for sessionID: UUID) -> [PiAgentTranscriptEntry] {
        loadTranscriptIfNeeded(sessionID)
        markTranscriptSessionUsed(sessionID)
        evictTranscriptsIfNeeded(protectingSessionID: sessionID)
        return transcriptsBySessionID[sessionID] ?? []
    }

    func requestSelectedTranscriptLoad() {
        guard let selectedSessionID else { return }
        requestTranscriptLoad(for: selectedSessionID)
    }

    func requestTranscriptLoad(for sessionID: UUID) {
        guard lazyTranscriptLoadingEnabled else {
            _ = transcript(for: sessionID)
            return
        }
        guard transcriptsBySessionID[sessionID] == nil else {
            markTranscriptSessionUsed(sessionID)
            evictTranscriptsIfNeeded(protectingSessionID: sessionID)
            return
        }
        guard persistedTranscriptSessionIDs.contains(sessionID) else { return }
        guard transcriptLoadTasksBySessionID[sessionID] == nil else { return }

        let fileURL = parentTranscriptURL(sessionID)
        transcriptLoadingSessionIDs.insert(sessionID)
        transcriptLoadTasksBySessionID[sessionID] = Task.detached(priority: .utility) { [weak self] in
            let entries = (try? Self.readParentTranscript(from: fileURL)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishRequestedTranscriptLoad(sessionID, entries: entries)
            }
        }
    }

    func requestSubagentTranscriptLoad(for runID: UUID) {
        guard lazyTranscriptLoadingEnabled else {
            _ = subagentTranscript(for: runID)
            return
        }
        guard subagentTranscriptsByRunID[runID] == nil else {
            markSubagentTranscriptUsed(runID)
            evictTranscriptsIfNeeded(protectingSubagentRunID: runID)
            return
        }
        guard persistedSubagentTranscriptRunIDs.contains(runID) else { return }
        guard subagentTranscriptLoadTasksByRunID[runID] == nil else { return }

        let fileURL = subagentTranscriptURL(runID)
        subagentTranscriptLoadTasksByRunID[runID] = Task.detached(priority: .utility) { [weak self] in
            let entries = (try? Self.readSubagentTranscript(from: fileURL)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finishRequestedSubagentTranscriptLoad(runID, entries: entries)
            }
        }
    }

    func supervisorRequests(for sessionID: UUID) -> [PiSubagentSupervisorRequest] {
        supervisorRequestsBySessionID[sessionID] ?? []
    }

    var selectedSupervisorRequests: [PiSubagentSupervisorRequest] {
        guard let session = selectedSession else { return [] }
        return supervisorRequests(for: session.id)
    }

    func sessionPlan(for sessionID: UUID) -> PiSessionPlanRecord? {
        sessionPlansBySessionID[sessionID]
    }

    func sessionPlanEvents(for sessionID: UUID) -> [PiSessionPlanEventRecord] {
        sessionPlanEventsBySessionID[sessionID] ?? []
    }

    func setSessionPlan(sessionID: UUID, items: [PiSessionPlanBridgeItem]) -> PiSessionPlanRecord {
        let now = Date()
        let existingPlan = sessionPlansBySessionID[sessionID]
        let planID = UUID()
        var seen = Set<String>()
        let records = items.prefix(12).enumerated().compactMap { index, item -> PiSessionPlanItemRecord? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let trimmedID = item.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let baseID = trimmedID.isEmpty ? slugID(for: title, fallback: "step-\(index + 1)") : trimmedID
            let id = uniquePlanItemID(baseID, seen: &seen)
            return PiSessionPlanItemRecord(id: id, title: title, status: item.status ?? (index == 0 ? .inProgress : .todo), updatedAt: now)
        }
        let record = PiSessionPlanRecord(id: planID, sessionID: sessionID, items: records, createdAt: now, updatedAt: now)
        if records.isEmpty {
            sessionPlansBySessionID[sessionID] = nil
            if let existingPlan {
                appendPlanEvent(sessionID: sessionID, planID: existingPlan.id, kind: .cleared, items: [], timestamp: now)
            }
        } else {
            sessionPlansBySessionID[sessionID] = record
            appendPlanEvent(sessionID: sessionID, planID: planID, kind: existingPlan == nil ? .created : .replaced, items: records, timestamp: now)
        }
        touchSession(sessionID, bumpUpdatedAt: true)
        return record
    }

    func updateSessionPlan(sessionID: UUID, updates: [PiSessionPlanBridgeUpdate]) -> PiSessionPlanRecord? {
        guard var plan = sessionPlansBySessionID[sessionID] else { return nil }
        let now = Date()
        var changed = false
        for update in updates.prefix(12) {
            guard let index = plan.items.firstIndex(where: { $0.id == update.id }) else { continue }
            var itemChanged = false
            if let title = update.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, plan.items[index].title != title {
                plan.items[index].title = title
                itemChanged = true
            }
            if let status = update.status, plan.items[index].status != status {
                plan.items[index].status = status
                itemChanged = true
            }
            if itemChanged {
                plan.items[index].updatedAt = now
                changed = true
            }
        }
        guard changed else { return plan }
        plan.updatedAt = now
        sessionPlansBySessionID[sessionID] = plan
        appendPlanEvent(sessionID: sessionID, planID: plan.id, kind: .updated, items: plan.items, timestamp: now)
        touchSession(sessionID, bumpUpdatedAt: false)
        return plan
    }

    func clearSessionPlan(sessionID: UUID) {
        let existingPlan = sessionPlansBySessionID[sessionID]
        sessionPlansBySessionID[sessionID] = nil
        if let existingPlan {
            appendPlanEvent(sessionID: sessionID, planID: existingPlan.id, kind: .cleared, items: [], timestamp: Date())
        }
        save()
    }

    private func appendPlanEvent(sessionID: UUID, planID: UUID, kind: PiSessionPlanEventKind, items: [PiSessionPlanItemRecord], timestamp: Date) {
        var events = sessionPlanEventsBySessionID[sessionID] ?? []
        events.append(PiSessionPlanEventRecord(id: UUID(), sessionID: sessionID, planID: planID, kind: kind, items: items, timestamp: timestamp))
        sessionPlanEventsBySessionID[sessionID] = Array(events.suffix(100))
    }

    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveNow()
    }

    func flushForTesting() {
        flushPendingSave()
    }

    private func slugID(for title: String, fallback: String) -> String {
        let slug = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : String(slug.prefix(48))
    }

    private func uniquePlanItemID(_ raw: String, seen: inout Set<String>) -> String {
        var candidate = raw
        var suffix = 2
        while seen.contains(candidate) {
            candidate = "\(raw)-\(suffix)"
            suffix += 1
        }
        seen.insert(candidate)
        return candidate
    }

    func upsertSubagentRun(_ run: PiSubagentRunRecord) {
        var runs = subagentRunsBySessionID[run.parentSessionID] ?? []
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
        }
        subagentRunsBySessionID[run.parentSessionID] = runs.sorted { $0.createdAt > $1.createdAt }
        touchSession(run.parentSessionID, bumpUpdatedAt: true)
    }

    func updateSubagentRun(_ runID: UUID, parentSessionID: UUID, mutate: (inout PiSubagentRunRecord) -> Void) {
        var runs = subagentRunsBySessionID[parentSessionID] ?? []
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        mutate(&runs[index])
        runs[index].updatedAt = Date()
        subagentRunsBySessionID[parentSessionID] = runs.sorted { $0.createdAt > $1.createdAt }
        touchSession(parentSessionID, bumpUpdatedAt: true)
    }

    func appendSubagentTranscript(_ entry: PiAgentTranscriptEntry, runID: UUID, parentSessionID: UUID) {
        modifySubagentTranscriptEntries(for: runID) { entries in
            entries.append(entry)
            trimTranscriptEntries(&entries)
        }
        persistSubagentTranscript(runID)
        markSubagentTranscriptUsed(runID)
        evictTranscriptsIfNeeded()
        touchSession(parentSessionID, bumpUpdatedAt: false)
    }

    func upsertSubagentTranscript(_ entry: PiAgentTranscriptEntry, runID: UUID, parentSessionID: UUID, before beforeEntryID: UUID? = nil) {
        modifySubagentTranscriptEntries(for: runID) { entries in
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else if let beforeEntryID, let beforeIndex = entries.firstIndex(where: { $0.id == beforeEntryID }) {
                entries.insert(entry, at: beforeIndex)
            } else {
                entries.append(entry)
            }
            trimTranscriptEntries(&entries)
        }
        persistSubagentTranscript(runID)
        markSubagentTranscriptUsed(runID)
        evictTranscriptsIfNeeded()
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
        modifyTranscriptEntries(for: entry.sessionID) { entries in
            entries.append(entry)
            trimTranscriptEntries(&entries)
        }
        persistTranscript(entry.sessionID)
        markTranscriptSessionUsed(entry.sessionID)
        evictTranscriptsIfNeeded()
        bumpTranscriptRevision(entry.sessionID)
        touchSession(entry.sessionID, bumpUpdatedAt: true)
    }

    func upsert(_ entry: PiAgentTranscriptEntry, before beforeEntryID: UUID? = nil, persist: Bool = true) {
        let isNewEntry: Bool
        var insertedEntry = false
        modifyTranscriptEntries(for: entry.sessionID) { entries in
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else if let beforeEntryID, let beforeIndex = entries.firstIndex(where: { $0.id == beforeEntryID }) {
                entries.insert(entry, at: beforeIndex)
                insertedEntry = true
            } else {
                entries.append(entry)
                insertedEntry = true
            }
            trimTranscriptEntries(&entries)
        }
        markTranscriptSessionUsed(entry.sessionID)
        isNewEntry = insertedEntry
        bumpTranscriptRevision(entry.sessionID)
        guard persist else { return }
        persistTranscript(entry.sessionID)
        evictTranscriptsIfNeeded()
        if isNewEntry {
            touchSession(entry.sessionID, bumpUpdatedAt: true)
        } else {
            save()
        }
    }

    func updateEntry(_ entryID: UUID, in sessionID: UUID, persist: Bool = true, mutate: (inout PiAgentTranscriptEntry) -> Void) {
        loadTranscriptIfNeeded(sessionID)
        guard transcriptsBySessionID[sessionID] != nil else { return }
        var didUpdate = false
        modifyTranscriptEntries(for: sessionID) { entries in
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            mutate(&entries[index])
            didUpdate = true
        }
        guard didUpdate else { return }
        markTranscriptSessionUsed(sessionID)
        bumpTranscriptRevision(sessionID)
        if persist {
            persistTranscript(sessionID)
            evictTranscriptsIfNeeded()
            save()
        }
    }

    func deleteSession(_ sessionID: UUID) {
        deleteSessions([sessionID])
    }

    func deleteSessions(_ sessionIDs: Set<UUID>) {
        let existingIDs = Set(sessions.map(\.id)).intersection(sessionIDs)
        guard !existingIDs.isEmpty else { return }

        sessions.removeAll { existingIDs.contains($0.id) }
        for sessionID in existingIDs {
            cancelTranscriptLoadTask(for: sessionID)
            transcriptsBySessionID[sessionID] = nil
            persistedTranscriptSessionIDs.remove(sessionID)
            loadedTranscriptSessionOrder.removeAll { $0 == sessionID }
            deleteTranscriptFile(sessionID)
            transcriptRevisionsBySessionID[sessionID] = nil
            let runIDs = subagentRunsBySessionID[sessionID]?.map(\.id) ?? []
            for runID in runIDs {
                cancelSubagentTranscriptLoadTask(for: runID)
                subagentTranscriptsByRunID[runID] = nil
                persistedSubagentTranscriptRunIDs.remove(runID)
                loadedSubagentTranscriptOrder.removeAll { $0 == runID }
                deleteSubagentTranscriptFile(runID)
            }
            subagentRunsBySessionID[sessionID] = nil
            supervisorRequestsBySessionID[sessionID] = nil
            sessionPlansBySessionID[sessionID] = nil
            sessionPlanEventsBySessionID[sessionID] = nil
        }
        if let currentSelectedSessionID = selectedSessionID, existingIDs.contains(currentSelectedSessionID) {
            selectedSessionID = sessions.first?.id
        }
        saveStructuralChange()
    }

    func clearTranscript(for sessionID: UUID) {
        cancelTranscriptLoadTask(for: sessionID)
        transcriptsBySessionID[sessionID] = []
        persistTranscript(sessionID)
        markTranscriptSessionUsed(sessionID)
        bumpTranscriptRevision(sessionID)
        save()
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            if lazyTranscriptLoadingEnabled, let manifest = loadTranscriptManifest() {
                let persisted = try JSONDecoder.piAgent.decode(PersistedStateIndex.self, from: data)
                applyPersistedIndex(persisted, manifest: manifest)
                return
            }

            let persisted = try JSONDecoder.piAgent.decode(PersistedState.self, from: data)
            sessions = persisted.sessions.map { session in
                var session = session
                if session.status.isActive {
                    session.status = .stopped
                    session.lastError = session.lastError ?? "Stopped because \(AppBrand.displayName) was restarted."
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
                        run.error = run.error ?? "Disconnected because \(AppBrand.displayName) was restarted."
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
            sessionPlansBySessionID = Dictionary(uniqueKeysWithValues: (persisted.sessionPlans ?? []).map { ($0.sessionID, $0) })
            sessionPlanEventsBySessionID = Dictionary(grouping: persisted.sessionPlanEvents ?? [], by: \.sessionID)
            for plan in sessionPlansBySessionID.values where sessionPlanEventsBySessionID[plan.sessionID]?.isEmpty != false {
                sessionPlanEventsBySessionID[plan.sessionID] = [
                    PiSessionPlanEventRecord(
                        id: UUID(),
                        sessionID: plan.sessionID,
                        planID: plan.id,
                        kind: .created,
                        items: plan.items,
                        timestamp: plan.createdAt
                    )
                ]
            }
            if let persistedSelectedSessionID = persisted.selectedSessionID,
               sessions.contains(where: { $0.id == persistedSelectedSessionID }) {
                selectedSessionID = persistedSelectedSessionID
            } else {
                selectedSessionID = sessions.first?.id
            }
            persistedTranscriptSessionIDs = Set(transcriptsBySessionID.keys)
            persistedSubagentTranscriptRunIDs = Set(subagentTranscriptsByRunID.keys)
            writeLoadedTranscriptFilesAndManifest()
            if lazyTranscriptLoadingEnabled {
                evictTranscriptsIfNeeded()
            }
        } catch {
            lastError = "Could not load Pi Agent sessions: \(error.localizedDescription)"
            sessions = []
            transcriptsBySessionID = [:]
            selectedSessionID = nil
        }
    }

    private func applyPersistedIndex(_ persisted: PersistedStateIndex, manifest: TranscriptManifest) {
        sessions = persisted.sessions.map { session in
            var session = session
            if session.status.isActive {
                session.status = .stopped
                session.lastError = session.lastError ?? "Stopped because \(AppBrand.displayName) was restarted."
            }
            session.isCompacting = false
            return session
        }
        sortSessions()
        transcriptsBySessionID = [:]
        persistedTranscriptSessionIDs = Set(manifest.parentSessionIDs)
        transcriptRevisionsBySessionID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, 0) })

        subagentRunsBySessionID = Dictionary(uniqueKeysWithValues: (persisted.subagentRuns ?? []).map { persistedRuns in
            let recovered = persistedRuns.runs.map { run -> PiSubagentRunRecord in
                var run = run
                if run.status.isActive {
                    let completedAt = Date()
                    run.status = .disconnected
                    run.error = run.error ?? "Disconnected because \(AppBrand.displayName) was restarted."
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

        subagentTranscriptsByRunID = [:]
        persistedSubagentTranscriptRunIDs = Set(manifest.subagentRunIDs)
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
        sessionPlansBySessionID = Dictionary(uniqueKeysWithValues: (persisted.sessionPlans ?? []).map { ($0.sessionID, $0) })
        sessionPlanEventsBySessionID = Dictionary(grouping: persisted.sessionPlanEvents ?? [], by: \.sessionID)
        for plan in sessionPlansBySessionID.values where sessionPlanEventsBySessionID[plan.sessionID]?.isEmpty != false {
            sessionPlanEventsBySessionID[plan.sessionID] = [
                PiSessionPlanEventRecord(
                    id: UUID(),
                    sessionID: plan.sessionID,
                    planID: plan.id,
                    kind: .created,
                    items: plan.items,
                    timestamp: plan.createdAt
                )
            ]
        }
        if let persistedSelectedSessionID = persisted.selectedSessionID,
           sessions.contains(where: { $0.id == persistedSelectedSessionID }) {
            selectedSessionID = persistedSelectedSessionID
        } else {
            selectedSessionID = sessions.first?.id
        }
        loadInitialTranscriptCache()
    }

    private func bumpTranscriptRevision(_ sessionID: UUID) {
        pendingTranscriptRevisionSessionIDs.insert(sessionID)
        guard pendingTranscriptRevisionTask == nil else { return }
        pendingTranscriptRevisionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.transcriptRevisionCoalesceNanoseconds ?? 33_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingTranscriptRevisions()
        }
    }

    private func flushPendingTranscriptRevisions() {
        let sessionIDs = pendingTranscriptRevisionSessionIDs
        pendingTranscriptRevisionSessionIDs.removeAll()
        pendingTranscriptRevisionTask = nil

        let existingSessionIDs = Set(sessions.map(\.id))
        for sessionID in sessionIDs where existingSessionIDs.contains(sessionID) {
            transcriptRevisionsBySessionID[sessionID, default: 0] += 1
        }
    }

    private func sortSessions() {
        sessions.sort { PiAgentSessionRecord.sessionListPrecedes($0, $1) }
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

    private func modifyTranscriptEntries(for sessionID: UUID, _ mutate: (inout [PiAgentTranscriptEntry]) -> Void) {
        loadTranscriptIfNeeded(sessionID)
        mutate(&transcriptsBySessionID[sessionID, default: []])
    }

    private func modifySubagentTranscriptEntries(for runID: UUID, _ mutate: (inout [PiAgentTranscriptEntry]) -> Void) {
        loadSubagentTranscriptIfNeeded(runID)
        mutate(&subagentTranscriptsByRunID[runID, default: []])
    }

    private func trimTranscriptEntries(_ entries: inout [PiAgentTranscriptEntry]) {
        if entries.count > maxTranscriptEntriesPerSession {
            entries.removeFirst(entries.count - maxTranscriptEntriesPerSession)
        }
    }

    private func loadInitialTranscriptCache() {
        guard !lazyTranscriptLoadingEnabled else { return }
        loadAllPersistedTranscriptsIntoMemory()
    }

    private func loadAllPersistedTranscriptsIntoMemory() {
        for sessionID in persistedTranscriptSessionIDs {
            loadTranscriptIfNeeded(sessionID)
            markTranscriptSessionUsed(sessionID)
        }
        for runID in persistedSubagentTranscriptRunIDs {
            loadSubagentTranscriptIfNeeded(runID)
            markSubagentTranscriptUsed(runID)
        }
    }

    private func loadTranscriptIfNeeded(_ sessionID: UUID) {
        guard transcriptsBySessionID[sessionID] == nil, persistedTranscriptSessionIDs.contains(sessionID) else { return }
        transcriptsBySessionID[sessionID] = (try? Self.readParentTranscript(from: parentTranscriptURL(sessionID))) ?? []
    }

    private func finishRequestedTranscriptLoad(_ sessionID: UUID, entries: [PiAgentTranscriptEntry]) {
        guard transcriptLoadTasksBySessionID[sessionID] != nil else { return }
        transcriptLoadTasksBySessionID[sessionID] = nil
        transcriptLoadingSessionIDs.remove(sessionID)
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        if transcriptsBySessionID[sessionID] == nil {
            transcriptsBySessionID[sessionID] = entries
        }
        transcriptRevisionsBySessionID[sessionID, default: 0] += 1
        markTranscriptSessionUsed(sessionID)
        evictTranscriptsIfNeeded(protectingSessionID: sessionID)
    }

    private func finishRequestedSubagentTranscriptLoad(_ runID: UUID, entries: [PiAgentTranscriptEntry]) {
        guard subagentTranscriptLoadTasksByRunID[runID] != nil else { return }
        subagentTranscriptLoadTasksByRunID[runID] = nil
        guard persistedSubagentTranscriptRunIDs.contains(runID) else { return }

        if subagentTranscriptsByRunID[runID] == nil {
            subagentTranscriptsByRunID[runID] = entries
        }
        markSubagentTranscriptUsed(runID)
        evictTranscriptsIfNeeded(protectingSubagentRunID: runID)
    }

    private func cancelTranscriptLoadTask(for sessionID: UUID) {
        transcriptLoadTasksBySessionID[sessionID]?.cancel()
        transcriptLoadTasksBySessionID[sessionID] = nil
        transcriptLoadingSessionIDs.remove(sessionID)
    }

    private func cancelSubagentTranscriptLoadTask(for runID: UUID) {
        subagentTranscriptLoadTasksByRunID[runID]?.cancel()
        subagentTranscriptLoadTasksByRunID[runID] = nil
    }

    private func cancelAllTranscriptLoadTasks() {
        for task in transcriptLoadTasksBySessionID.values {
            task.cancel()
        }
        for task in subagentTranscriptLoadTasksByRunID.values {
            task.cancel()
        }
        transcriptLoadTasksBySessionID = [:]
        subagentTranscriptLoadTasksByRunID = [:]
        transcriptLoadingSessionIDs = []
    }

    private func loadSubagentTranscriptIfNeeded(_ runID: UUID) {
        guard subagentTranscriptsByRunID[runID] == nil, persistedSubagentTranscriptRunIDs.contains(runID) else { return }
        subagentTranscriptsByRunID[runID] = (try? Self.readSubagentTranscript(from: subagentTranscriptURL(runID))) ?? []
    }

    private func evictTranscriptsIfNeeded(protectingSessionID: UUID? = nil, protectingSubagentRunID: UUID? = nil) {
        guard lazyTranscriptLoadingEnabled else { return }
        let protectedSessionIDs = Set([selectedSessionID, protectingSessionID].compactMap { $0 })
            .union(sessions.filter { $0.status.isActive }.map(\.id))
        while loadedTranscriptSessionOrder.count > transcriptCacheLimit,
              let evictID = loadedTranscriptSessionOrder.first(where: { !protectedSessionIDs.contains($0) }) {
            loadedTranscriptSessionOrder.removeAll { $0 == evictID }
            transcriptsBySessionID[evictID] = nil
        }
        while loadedSubagentTranscriptOrder.count > transcriptCacheLimit,
              let evictID = loadedSubagentTranscriptOrder.first(where: { $0 != protectingSubagentRunID }) {
            loadedSubagentTranscriptOrder.removeAll { $0 == evictID }
            subagentTranscriptsByRunID[evictID] = nil
        }
    }

    private func markTranscriptSessionUsed(_ sessionID: UUID) {
        loadedTranscriptSessionOrder.removeAll { $0 == sessionID }
        loadedTranscriptSessionOrder.append(sessionID)
    }

    private func markSubagentTranscriptUsed(_ runID: UUID) {
        loadedSubagentTranscriptOrder.removeAll { $0 == runID }
        loadedSubagentTranscriptOrder.append(runID)
    }

    private func persistTranscript(_ sessionID: UUID) {
        guard let entries = transcriptsBySessionID[sessionID] else { return }
        persistedTranscriptSessionIDs.insert(sessionID)
        let url = parentTranscriptURL(sessionID)
        saveQueue.async {
            try? Self.writeParentTranscript(PersistedTranscript(sessionID: sessionID, entries: entries), to: url)
        }
    }

    private func persistSubagentTranscript(_ runID: UUID) {
        guard let entries = subagentTranscriptsByRunID[runID] else { return }
        persistedSubagentTranscriptRunIDs.insert(runID)
        let url = subagentTranscriptURL(runID)
        saveQueue.async {
            try? Self.writeSubagentTranscript(PersistedSubagentTranscript(runID: runID, entries: entries), to: url)
        }
    }

    private func writeLoadedTranscriptFilesAndManifest() {
        for sessionID in persistedTranscriptSessionIDs {
            persistTranscript(sessionID)
        }
        for runID in persistedSubagentTranscriptRunIDs {
            persistSubagentTranscript(runID)
        }
        persistTranscriptManifest()
    }

    private func loadTranscriptManifest() -> TranscriptManifest? {
        guard let data = try? Data(contentsOf: transcriptManifestURL) else { return nil }
        return try? JSONDecoder.piAgent.decode(TranscriptManifest.self, from: data)
    }

    private func persistTranscriptManifest() {
        let manifest = TranscriptManifest(
            parentSessionIDs: Array(persistedTranscriptSessionIDs),
            subagentRunIDs: Array(persistedSubagentTranscriptRunIDs)
        )
        let url = transcriptManifestURL
        saveQueue.async {
            try? Self.writeTranscriptManifest(manifest, to: url)
        }
    }

    private func parentTranscriptURL(_ sessionID: UUID) -> URL {
        transcriptsDirectoryURL.appendingPathComponent("parent-\(sessionID.uuidString).json")
    }

    private func subagentTranscriptURL(_ runID: UUID) -> URL {
        transcriptsDirectoryURL.appendingPathComponent("subagent-\(runID.uuidString).json")
    }

    private func deleteTranscriptFile(_ sessionID: UUID) {
        let url = parentTranscriptURL(sessionID)
        saveQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteSubagentTranscriptFile(_ runID: UUID) {
        let url = subagentTranscriptURL(runID)
        saveQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func save() {
        scheduleSave(after: defaultSaveDebounceNanoseconds)
    }

    private func saveStructuralChange() {
        scheduleSave(after: structuralSaveDebounceNanoseconds)
    }

    private func scheduleSave(after nanoseconds: UInt64) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.saveNowAsync()
            }
        }
    }

    private func makePersistedStateSnapshot() -> (sequence: Int, state: PersistedState) {
        saveSequence &+= 1
        let persisted = PersistedState(
            sessions: sessions,
            transcripts: transcriptsBySessionID.map { PersistedTranscript(sessionID: $0.key, entries: $0.value) },
            selectedSessionID: selectedSessionID,
            subagentRuns: subagentRunsBySessionID.map { PersistedSubagentRuns(sessionID: $0.key, runs: $0.value) },
            subagentTranscripts: subagentTranscriptsByRunID.map { PersistedSubagentTranscript(runID: $0.key, entries: $0.value) },
            supervisorRequests: supervisorRequestsBySessionID.map { PersistedSupervisorRequests(sessionID: $0.key, requests: $0.value) },
            sessionPlans: Array(sessionPlansBySessionID.values),
            sessionPlanEvents: Array(sessionPlanEventsBySessionID.values.joined())
        )
        return (saveSequence, persisted)
    }

    private func saveNowAsync() {
        let fileURL = fileURL
        let transcriptManifestURL = transcriptManifestURL
        let manifest = makeTranscriptManifestSnapshot()
        let (sequence, persisted) = makePersistedStateSnapshot()
        saveQueue.async { [weak self, fileURL, transcriptManifestURL, manifest, persisted, sequence] in
            do {
                try Self.writeTranscriptManifest(manifest, to: transcriptManifestURL)
                try Self.write(persisted, to: fileURL)
            } catch {
                let message = "Could not save Pi Agent sessions: \(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    guard let self, self.saveSequence == sequence else { return }
                    self.lastError = message
                }
            }
        }
    }

    private func saveNow() {
        let fileURL = fileURL
        let transcriptManifestURL = transcriptManifestURL
        let manifest = makeTranscriptManifestSnapshot()
        let (_, persisted) = makePersistedStateSnapshot()
        do {
            try saveQueue.sync {
                try Self.writeTranscriptManifest(manifest, to: transcriptManifestURL)
                try Self.write(persisted, to: fileURL)
            }
        } catch {
            lastError = "Could not save Pi Agent sessions: \(error.localizedDescription)"
        }
    }

    private func makeTranscriptManifestSnapshot() -> TranscriptManifest {
        TranscriptManifest(
            parentSessionIDs: Array(persistedTranscriptSessionIDs),
            subagentRunIDs: Array(persistedSubagentTranscriptRunIDs)
        )
    }

    private nonisolated static func write(_ persisted: PersistedState, to fileURL: URL) throws {
        let data = try JSONEncoder.piAgent.encode(persisted)
        try data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func writeParentTranscript(_ transcript: PersistedTranscript, to fileURL: URL) throws {
        let data = try JSONEncoder.piAgent.encode(transcript)
        try data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func readParentTranscript(from fileURL: URL) throws -> [PiAgentTranscriptEntry] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.piAgent.decode(PersistedTranscript.self, from: data).entries
    }

    private nonisolated static func writeSubagentTranscript(_ transcript: PersistedSubagentTranscript, to fileURL: URL) throws {
        let data = try JSONEncoder.piAgent.encode(transcript)
        try data.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func readSubagentTranscript(from fileURL: URL) throws -> [PiAgentTranscriptEntry] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.piAgent.decode(PersistedSubagentTranscript.self, from: data).entries
    }

    private nonisolated static func writeTranscriptManifest(_ manifest: TranscriptManifest, to fileURL: URL) throws {
        let data = try JSONEncoder.piAgent.encode(manifest)
        try data.write(to: fileURL, options: .atomic)
    }
}

private nonisolated struct PersistedState: Codable {
    var sessions: [PiAgentSessionRecord]
    var transcripts: [PersistedTranscript]
    var selectedSessionID: UUID?
    var subagentRuns: [PersistedSubagentRuns]?
    var subagentTranscripts: [PersistedSubagentTranscript]?
    var supervisorRequests: [PersistedSupervisorRequests]?
    var sessionPlans: [PiSessionPlanRecord]?
    var sessionPlanEvents: [PiSessionPlanEventRecord]?
}

private nonisolated struct PersistedStateIndex: Codable {
    var sessions: [PiAgentSessionRecord]
    var selectedSessionID: UUID?
    var subagentRuns: [PersistedSubagentRuns]?
    var supervisorRequests: [PersistedSupervisorRequests]?
    var sessionPlans: [PiSessionPlanRecord]?
    var sessionPlanEvents: [PiSessionPlanEventRecord]?
}

private nonisolated struct PersistedTranscript: Codable {
    var sessionID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private nonisolated struct PersistedSubagentRuns: Codable {
    var sessionID: UUID
    var runs: [PiSubagentRunRecord]
}

private nonisolated struct PersistedSubagentTranscript: Codable {
    var runID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private nonisolated struct PersistedSupervisorRequests: Codable {
    var sessionID: UUID
    var requests: [PiSubagentSupervisorRequest]
}

private nonisolated struct TranscriptManifest: Codable {
    var parentSessionIDs: [UUID]
    var subagentRunIDs: [UUID]
}

private nonisolated extension JSONEncoder {
    static var piAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private nonisolated extension JSONDecoder {
    static var piAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
