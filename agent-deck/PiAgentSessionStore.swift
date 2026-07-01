import AppKit
import Combine
import Foundation
import Observation

private extension String {
    var safeFilenameComponent: String {
        let slug = lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "stage" : String(slug.prefix(48))
    }
}

@MainActor
@Observable
final class PiAgentSessionStore {
    private(set) var sessions: [PiAgentSessionRecord] = []
    /// Bumps only when the session list's membership, order, or per-row visibility-relevant
    /// fields (needsAttention, title, projectPath) change. Streaming token / stats writes
    /// hit `sessions[index]` many times per frame; observing the array directly fires
    /// SwiftUI's "onChange action ran multiple times per frame" warning. Views that just
    /// need to rebuild a filtered/sorted snapshot should `.onChange(of:)` this counter.
    private(set) var sessionListRevision: Int = 0
    /// De-noised "broad change" signal for `subagentRunsBySessionID`. Same
    /// pattern as `sessionListRevision`: every dict write fires a full
    /// `@Observable` invalidation, but consumers usually only need to
    /// re-evaluate a filtered/sorted layout. Views should `.onChange(of:)` /
    /// `.task(id:)` this counter and re-read the dict in the handler.
    private(set) var subagentRunsRevision: Int = 0
    /// Same broad revision for supervisor requests. Transcript item memoization
    /// reads this instead of hashing every full request record on each body pass.
    private(set) var supervisorRequestsRevision: Int = 0
    private(set) var transcriptsBySessionID: [UUID: [PiAgentTranscriptEntry]] = [:]
    private(set) var transcriptLoadingSessionIDs: Set<UUID> = []
    private(set) var transcriptRevisionsBySessionID: [UUID: Int] = [:]
    /// Coarse "a git event (commit / push / merge) landed in some transcript"
    /// signal. `transcriptRevisionsBySessionID` pulses ~30Hz during streaming, but
    /// the session list's git-activity badges only ever change when one of these
    /// discrete status entries is appended. Badge consumers `.onChange(of:)` this
    /// counter instead, so a streaming run no longer re-evaluates their body per
    /// token — only when the badges could actually have changed.
    private(set) var gitActivityRevision: Int = 0
    private(set) var uiRequestsBySessionID: [UUID: PiAgentUIRequest] = [:]
    private(set) var subagentRunsBySessionID: [UUID: [PiSubagentRunRecord]] = [:] {
        didSet { subagentRunsRevision &+= 1 }
    }
    private(set) var subagentTranscriptsByRunID: [UUID: [PiAgentTranscriptEntry]] = [:]
    private(set) var supervisorRequestsBySessionID: [UUID: [PiSubagentSupervisorRequest]] = [:] {
        didSet { supervisorRequestsRevision &+= 1 }
    }
    private(set) var sessionPlansBySessionID: [UUID: PiSessionPlanRecord] = [:]
    private(set) var sessionPlanEventsBySessionID: [UUID: [PiSessionPlanEventRecord]] = [:]
    private(set) var loopRunsBySessionID: [UUID: [LoopRun]] = [:]
    /// Live, RPC-derived activity for sessions with a turn in flight. Not persisted —
    /// it only describes the current process and is cleared when a turn ends.
    private(set) var processingActivityBySessionID: [UUID: PiAgentProcessingActivity] = [:]
    /// Sessions created or touched (`updatedAt` bumped) during the current app
    /// run. Populated by `createSession` and `touchSession(bumpUpdatedAt: true)`
    /// — disk-load paths (`applyPersistedIndex`, `applyFullPersistedState`) do
    /// NOT touch it, so launch-time recovery of previously-active sessions does
    /// not pollute the run's touched set. Drives the expanded sidebar's preview:
    /// touched-this-run sessions surface above the top-N cap so a freshly-jostled
    /// older chat stays reachable without taking the whole project over the cap.
    private(set) var sessionsTouchedThisRun: Set<UUID> = []
    var selectedSessionID: UUID?
    var lastError: String?
    var newSessionSubagentsEnabled = true
    /// Fired once after the async init load has applied the persisted sessions.
    /// AppViewModel hooks launch-time maintenance here (pruning never-started
    /// drafts) so cleanup runs against the loaded records, not the empty
    /// first-frame state.
    var onLoadApplied: (() -> Void)?

    private var composerTextDraftsBySessionID: [UUID: String] = [:]
    private var composerImageDraftsBySessionID: [UUID: [PiAgentImageAttachment]] = [:]
    private var composerPasteDraftsBySessionID: [UUID: [PiAgentPasteAttachment]] = [:]
    private var composerFileDraftsBySessionID: [UUID: [PiAgentFileAttachment]] = [:]
    private var composerFolderDraftsBySessionID: [UUID: [PiAgentFolderAttachment]] = [:]

    private let maxTranscriptEntriesPerSession = 500
    private let transcriptRevisionCoalesceNanoseconds: UInt64 = 66_000_000
    private let defaultSaveDebounceNanoseconds: UInt64 = 450_000_000
    private let structuralSaveDebounceNanoseconds: UInt64 = 50_000_000
    // Coalesces transcript file writes so per-token / per-tool-update streaming doesn't
    // re-encode and rewrite the entire transcript file dozens of times per second.
    // The debounce is shorter than the user-visible save indicator and long enough to
    // amortize one write per ~10 streaming flushes.
    private let transcriptPersistDebounceNanoseconds: UInt64 = 750_000_000
    private let fileURL: URL
    private let transcriptsDirectoryURL: URL
    private let transcriptManifestURL: URL
    private let saveQueue = DispatchQueue(label: "agent-deck.pi-agent-session-store.save", qos: .utility)
    private var pendingSaveTask: Task<Void, Never>?
    private var saveSequence = 0
    private var pendingTranscriptRevisionSessionIDs: Set<UUID> = []
    private var pendingTranscriptRevisionTask: Task<Void, Never>?
    // Snapshot of entries captured when persistTranscript was last called for a session.
    // Captured at call time (not flush time) so eviction of in-memory transcripts can't
    // race with the debounce and produce an empty on-disk transcript.
    private var pendingPersistTranscriptSnapshots: [UUID: [PiAgentTranscriptEntry]] = [:]
    private var pendingPersistSubagentTranscriptSnapshots: [UUID: [PiAgentTranscriptEntry]] = [:]
    private var pendingPersistTranscriptTask: Task<Void, Never>?
    // Transcripts always load on demand; only `configureTranscriptMemory` (tests) changes these.
    private var lazyTranscriptLoadingEnabled = true
    // Sized so a typical working set (plus the prewarmed neighbors of each
    // selection) stays decoded — at 10, cycling a dozen sessions evicted and
    // re-decoded on every visit, which is what made each switch hold briefly.
    private var transcriptCacheLimit = 24
    // Transcripts larger than this decode on the background loader instead of
    // synchronously on the main actor, to avoid a switch-time hitch.
    private static let maxSyncDecodeTranscriptBytes = 256 * 1024
    private var persistedTranscriptSessionIDs: Set<UUID> = []
    private var persistedSubagentTranscriptRunIDs: Set<UUID> = []
    private var loadedTranscriptSessionOrder: [UUID] = []
    private var loadedSubagentTranscriptOrder: [UUID] = []
    private var loopRecoverySessionIDs: Set<UUID> = []
    private var transcriptLoadTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var subagentTranscriptLoadTasksByRunID: [UUID: Task<Void, Never>] = [:]

    init(fileManager: FileManager = .default) {
        let appSupport = URL.applicationSupportDirectory
        let directory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("agent-sessions.json")
        transcriptsDirectoryURL = directory.appendingPathComponent("agent-session-transcripts", isDirectory: true)
        transcriptManifestURL = transcriptsDirectoryURL.appendingPathComponent("manifest.json")
        try? fileManager.createDirectory(at: transcriptsDirectoryURL, withIntermediateDirectories: true)
        scheduleLoad()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        transcriptsDirectoryURL = directory.appendingPathComponent("agent-session-transcripts", isDirectory: true)
        transcriptManifestURL = transcriptsDirectoryURL.appendingPathComponent("manifest.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcriptsDirectoryURL, withIntermediateDirectories: true)
        scheduleLoad()
    }

    /// Tracks the in-flight init load so tests can deterministically wait for
    /// it via `waitForLoadForTesting()`. Cleared once the load applies.
    private var loadTask: Task<Void, Never>?

    /// Kick off the on-disk load asynchronously so `init` (and therefore
    /// `AppViewModel.init`) returns immediately. Views render with `sessions == []`
    /// for a frame, then animate in once `applyLoadedPersistedState` fires.
    private func scheduleLoad() {
        let fileURL = self.fileURL
        let transcriptManifestURL = self.transcriptManifestURL
        let lazy = self.lazyTranscriptLoadingEnabled
        loadTask = Task { @MainActor [weak self] in
            let loaded = await Self.readPersisted(
                fileURL: fileURL,
                transcriptManifestURL: transcriptManifestURL,
                lazyTranscriptLoadingEnabled: lazy
            )
            self?.applyLoadedPersistedState(loaded)
            self?.loadTask = nil
            self?.onLoadApplied?()
        }
    }

    /// Awaits the in-flight init load. Test-only — production code observes
    /// `sessions` via `@Observable` and re-renders when it fills in.
    func waitForLoadForTesting() async {
        await loadTask?.value
    }

    /// Off-main read + JSON decode. Returns a `LoadedPersistedState` value to
    /// avoid any cross-actor mutation; the caller applies it on `@MainActor`.
    nonisolated private static func readPersisted(
        fileURL: URL,
        transcriptManifestURL: URL,
        lazyTranscriptLoadingEnabled: Bool
    ) async -> LoadedPersistedState {
        await Task.detached(priority: .userInitiated) { () -> LoadedPersistedState in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
            do {
                let data = try Data(contentsOf: fileURL)
                if lazyTranscriptLoadingEnabled,
                   let manifestData = try? Data(contentsOf: transcriptManifestURL),
                   let manifest = try? JSONDecoder.piAgent.decode(TranscriptManifest.self, from: manifestData) {
                    let persisted = try JSONDecoder.piAgent.decode(PersistedStateIndex.self, from: data)
                    return .lazy(persisted, manifest)
                }
                let persisted = try JSONDecoder.piAgent.decode(PersistedState.self, from: data)
                return .full(persisted)
            } catch {
                return .error(error.localizedDescription)
            }
        }.value
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

    func composerDraft(for sessionID: UUID) -> (text: String, pasteAttachments: [PiAgentPasteAttachment], images: [PiAgentImageAttachment], files: [PiAgentFileAttachment], folders: [PiAgentFolderAttachment]) {
        (
            composerTextDraftsBySessionID[sessionID] ?? "",
            composerPasteDraftsBySessionID[sessionID] ?? [],
            composerImageDraftsBySessionID[sessionID] ?? [],
            composerFileDraftsBySessionID[sessionID] ?? [],
            composerFolderDraftsBySessionID[sessionID] ?? []
        )
    }

    func saveComposerDraft(text: String, pasteAttachments: [PiAgentPasteAttachment] = [], images: [PiAgentImageAttachment], files: [PiAgentFileAttachment], folders: [PiAgentFolderAttachment], for sessionID: UUID) {
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: text, attachments: pasteAttachments)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activePasteAttachments.isEmpty && images.isEmpty && files.isEmpty && folders.isEmpty {
            clearComposerDraft(for: sessionID)
        } else {
            composerTextDraftsBySessionID[sessionID] = text
            composerPasteDraftsBySessionID[sessionID] = activePasteAttachments
            composerImageDraftsBySessionID[sessionID] = images
            composerFileDraftsBySessionID[sessionID] = files
            composerFolderDraftsBySessionID[sessionID] = folders
        }
    }

    func clearComposerDraft(for sessionID: UUID) {
        composerTextDraftsBySessionID.removeValue(forKey: sessionID)
        composerPasteDraftsBySessionID.removeValue(forKey: sessionID)
        composerImageDraftsBySessionID.removeValue(forKey: sessionID)
        composerFileDraftsBySessionID.removeValue(forKey: sessionID)
        composerFolderDraftsBySessionID.removeValue(forKey: sessionID)
    }

    @discardableResult
    func createNoProjectCodingAgentSession(title: String = "Draft · General Chat", model: String? = nil) -> PiAgentSessionRecord {
        createSession(
            kind: .project,
            title: title,
            projectPath: "",
            projectName: PiAgentSessionRecord.noProjectDisplayName,
            repository: nil,
            model: model,
            subagentsEnabled: false
        )
    }

    @discardableResult
    func createSession(kind: PiAgentSessionKind, title: String, project: DiscoveredProject, repository: String?, issueNumber: Int? = nil, issueURL: URL? = nil, model: String? = nil, worktreePath: String? = nil, branchName: String? = nil, sourceBranch: String? = nil, agentName: String? = nil) -> PiAgentSessionRecord {
        createSession(
            kind: kind,
            title: title,
            projectPath: project.path,
            projectName: project.name,
            repository: repository,
            issueNumber: issueNumber,
            issueURL: issueURL,
            model: model,
            worktreePath: worktreePath,
            branchName: branchName,
            sourceBranch: sourceBranch,
            agentName: agentName,
            subagentsEnabled: newSessionSubagentsEnabled
        )
    }

    @discardableResult
    private func createSession(kind: PiAgentSessionKind, title: String, projectPath: String, projectName: String, repository: String?, issueNumber: Int? = nil, issueURL: URL? = nil, model: String? = nil, worktreePath: String? = nil, branchName: String? = nil, sourceBranch: String? = nil, agentName: String? = nil, subagentsEnabled: Bool) -> PiAgentSessionRecord {
        let now = Date()
        let record = PiAgentSessionRecord(
            id: UUID(),
            kind: kind,
            title: title.isEmpty ? "New Agent Session" : title,
            projectPath: projectPath,
            projectName: projectName,
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
            branchName: branchName,
            worktreePath: worktreePath,
            sourceBranch: sourceBranch,
            status: .draft,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
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
            subagentsEnabled: subagentsEnabled,
            injectedExtensions: nil,
            agentName: agentName,
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(record, at: 0)
        sessionsTouchedThisRun.insert(record.id)
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
            prewarmNeighborTranscripts(of: id)
        } else {
            _ = transcript(for: id)
        }
        saveStructuralChange()
    }

    /// Kick background decodes for the sessions adjacent to the selection in
    /// list order (same project scope), so stepping through sessions — clicks
    /// down the sidebar, or cycling with the next/previous shortcuts — lands on
    /// an already-decoded transcript and the switch swaps with no hold at all.
    /// `requestTranscriptLoad` no-ops for transcripts that are already warm.
    private func prewarmNeighborTranscripts(of id: UUID) {
        guard let selected = sessions.first(where: { $0.id == id }) else { return }
        let scoped = sessions
            .filter { $0.projectPath == selected.projectPath && $0.isNoProject == selected.isNoProject }
            .sorted { PiAgentSessionRecord.sessionListPrecedes($0, $1) }
        guard let index = scoped.firstIndex(where: { $0.id == id }) else { return }
        for offset in [1, -1, 2] {
            let neighbor = index + offset
            guard scoped.indices.contains(neighbor) else { continue }
            requestTranscriptLoad(for: scoped[neighbor].id)
        }
    }

    /// Materializes a forked session record inheriting the parent's settings.
    /// Snapshots the parent transcript as plain text so the fork-origin card
    /// can render it independent of the parent record's lifetime. Seeds the
    /// composer with the user-message text Pi returned from /fork. The new
    /// session is auto-selected.
    @discardableResult
    func forkSession(
        from parent: PiAgentSessionRecord,
        newPiSessionFile: String,
        newPiSessionId: String?,
        composerSeed: String,
        cutBeforeEntryID: UUID? = nil
    ) -> PiAgentSessionRecord {
        let now = Date()
        let snapshot = parentTranscriptPlainText(parentID: parent.id, cutBeforeEntryID: cutBeforeEntryID)
        let title = "Fork of \(parent.title)"
        let record = PiAgentSessionRecord(
            id: UUID(),
            kind: .project,
            title: title,
            projectPath: parent.projectPath,
            projectName: parent.projectName,
            repository: parent.repository,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: newPiSessionFile,
            piSessionId: newPiSessionId,
            model: parent.model,
            modelProvider: parent.modelProvider,
            modelOverrideID: parent.modelOverrideID,
            modelOverrideProvider: parent.modelOverrideProvider,
            commandInvocations: nil,
            thinkingLevel: parent.thinkingLevel,
            launchCommand: nil,
            branchName: parent.branchName,
            worktreePath: parent.worktreePath,
            sourceBranch: parent.sourceBranch,
            status: .idle,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
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
            contextBreakdown: [],
            cost: nil,
            finalSystemPrompt: nil,
            finalSystemPromptCapturedAt: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: parent.subagentsEnabled,
            agentSelection: parent.agentSelection,
            injectedExtensions: parent.injectedExtensions,
            isCompacting: false,
            isTitleUserEdited: false,
            forkedFromSessionID: parent.id,
            forkedFromParentTitle: parent.title,
            forkedFromUserMessageText: composerSeed.isEmpty ? nil : composerSeed,
            forkedFromTranscriptSnapshot: snapshot.isEmpty ? nil : snapshot,
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(record, at: 0)
        sessionsTouchedThisRun.insert(record.id)
        sortSessions()
        transcriptsBySessionID[record.id] = []
        transcriptRevisionsBySessionID[record.id] = 0
        uiRequestsBySessionID[record.id] = nil
        subagentRunsBySessionID[record.id] = []
        supervisorRequestsBySessionID[record.id] = []
        sessionPlansBySessionID[record.id] = nil
        sessionPlanEventsBySessionID[record.id] = []
        if !composerSeed.isEmpty {
            saveComposerDraft(text: composerSeed, images: [], files: [], folders: [], for: record.id)
        }
        selectedSessionID = record.id
        markTranscriptSessionUsed(record.id)
        saveStructuralChange()
        return record
    }

    /// Materializes a 1:1 agent-chat session forked from a normal session's user
    /// message. Mirrors `forkSession` but creates a `.agent` kind record bound
    /// to `agent` — no Pi `/fork` RPC, no transcript replay (the agent's
    /// system prompt is incompatible with the parent's). Instead we snapshot
    /// the parent transcript for the recap card and seed the composer with the
    /// user-message text so the user can review/edit before sending. The new
    /// session is auto-selected and stays `.idle` until the user sends.
    @discardableResult
    func forkSessionAsAgentChat(
        from parent: PiAgentSessionRecord,
        agent: EffectiveAgentRecord,
        composerSeed: String,
        cutBeforeEntryID: UUID? = nil
    ) -> PiAgentSessionRecord {
        let now = Date()
        let snapshot = parentTranscriptPlainText(parentID: parent.id, cutBeforeEntryID: cutBeforeEntryID)
        let title = "Chat · \(agent.name)"
        let record = PiAgentSessionRecord(
            id: UUID(),
            kind: .agent,
            title: title,
            projectPath: parent.projectPath,
            projectName: parent.projectName,
            repository: parent.repository,
            issueNumber: nil,
            issueURL: nil,
            piSessionFile: nil,
            piSessionId: nil,
            model: nil,
            modelProvider: nil,
            modelOverrideID: nil,
            modelOverrideProvider: nil,
            commandInvocations: nil,
            thinkingLevel: nil,
            launchCommand: nil,
            branchName: parent.branchName,
            worktreePath: parent.worktreePath,
            sourceBranch: parent.sourceBranch,
            status: .idle,
            lastError: nil,
            lastSummary: nil,
            needsAttention: false,
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
            contextBreakdown: [],
            cost: nil,
            finalSystemPrompt: nil,
            finalSystemPromptCapturedAt: nil,
            pendingSteeringMessages: [],
            pendingFollowUpMessages: [],
            subagentsEnabled: false,
            agentSelection: nil,
            injectedExtensions: parent.injectedExtensions,
            agentName: agent.name,
            isCompacting: false,
            isTitleUserEdited: false,
            forkedFromSessionID: parent.id,
            forkedFromParentTitle: parent.title,
            forkedFromUserMessageText: composerSeed.isEmpty ? nil : composerSeed,
            forkedFromTranscriptSnapshot: snapshot.isEmpty ? nil : snapshot,
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(record, at: 0)
        sessionsTouchedThisRun.insert(record.id)
        sortSessions()
        transcriptsBySessionID[record.id] = []
        transcriptRevisionsBySessionID[record.id] = 0
        uiRequestsBySessionID[record.id] = nil
        subagentRunsBySessionID[record.id] = []
        supervisorRequestsBySessionID[record.id] = []
        sessionPlansBySessionID[record.id] = nil
        sessionPlanEventsBySessionID[record.id] = []
        if !composerSeed.isEmpty {
            saveComposerDraft(text: composerSeed, images: [], files: [], folders: [], for: record.id)
        }
        selectedSessionID = record.id
        markTranscriptSessionUsed(record.id)
        saveStructuralChange()
        return record
    }

    /// Renders the parent transcript as plain text for the fork-origin card popover
    /// and the agent-chat context injection. Includes user prompts, assistant
    /// replies, and thinking turns; skips status, tool, error, stderr, and raw
    /// noise. Survives parent deletion because the result is stored on the forked
    /// record. `cutBeforeEntryID` truncates at the forked-at message, so the
    /// snapshot reflects exactly the history the fork inherited — not the parent
    /// turns past the fork point, which never carried over.
    private func parentTranscriptPlainText(parentID: UUID, cutBeforeEntryID: UUID? = nil) -> String {
        let entries = transcript(for: parentID)
        var lines: [String] = []
        for entry in entries {
            if let cutBeforeEntryID, entry.id == cutBeforeEntryID { break }
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch entry.role {
            case .user:
                lines.append("User:\n\(trimmed)")
            case .assistant:
                lines.append("Assistant:\n\(trimmed)")
            case .thinking:
                lines.append("Thinking:\n\(trimmed)")
            case .tool, .status, .error, .stderr, .raw:
                continue
            }
        }
        return lines.joined(separator: "\n\n")
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
        // Avoid an unconditional sortSessions() — every `sessions.sort` is an Observable
        // write on `sessions`, and many per-frame calls during streaming were tripping
        // SwiftUI's "onChange action ran multiple times per frame" warning. Only the
        // fields used by `sessionListPrecedes` can change order: `updatedAt` compared
        // at .day granularity (so same-day updates never reorder).
        let preUpdatedAtDay = Calendar.current.startOfDay(for: sessions[index].updatedAt)
        let preNeedsAttention = sessions[index].needsAttention
        let preTitle = sessions[index].title
        let preProjectPath = sessions[index].projectPath
        let preStatus = sessions[index].status
        mutate(&sessions[index])
        if bumpUpdatedAt {
            sessions[index].updatedAt = Date()
        }
        let postUpdatedAtDay = Calendar.current.startOfDay(for: sessions[index].updatedAt)
        if postUpdatedAtDay != preUpdatedAtDay {
            sortSessions()
        } else if sessions[index].needsAttention != preNeedsAttention
            || sessions[index].title != preTitle
            || sessions[index].projectPath != preProjectPath
            // Status drives the row's ACTIVE badge. The session list renders from a
            // cached snapshot (`cachedSections`) that only rebuilds on a
            // `sessionListRevision` bump, so without this a stop (→ .stopped) left the
            // row showing a stale ACTIVE badge. Only transitions reach here (no change
            // → no bump), so streaming's steady .running stays cheap.
            || sessions[index].status != preStatus {
            bumpSessionListRevision()
        }
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

    func hasCachedSubagentTranscript(for runID: UUID) -> Bool {
        subagentTranscriptsByRunID[runID] != nil
    }

    func hasPersistedSubagentTranscript(for runID: UUID) -> Bool {
        persistedSubagentTranscriptRunIDs.contains(runID)
    }

    func isSubagentTranscriptLoadPending(for runID: UUID) -> Bool {
        subagentTranscriptLoadTasksByRunID[runID] != nil
    }

    func transcript(for sessionID: UUID) -> [PiAgentTranscriptEntry] {
        loadTranscriptIfNeeded(sessionID)
        markTranscriptSessionUsed(sessionID)
        evictTranscriptsIfNeeded(protectingSessionID: sessionID)
        return transcriptsBySessionID[sessionID] ?? []
    }

    /// Hydrates the transcript for the render cache without ever blocking the main
    /// thread on a large decode. Small transcripts decode synchronously (instant,
    /// no spinner); large ones go to the background loader and an empty snapshot is
    /// returned so the "Loading transcript" card shows until the load completes and
    /// bumps the revision, which re-runs this cache update.
    func transcriptForCacheUpdate(_ sessionID: UUID) -> [PiAgentTranscriptEntry] {
        if let loaded = transcriptsBySessionID[sessionID] {
            markTranscriptSessionUsed(sessionID)
            evictTranscriptsIfNeeded(protectingSessionID: sessionID)
            return loaded
        }
        guard lazyTranscriptLoadingEnabled,
              persistedTranscriptSessionIDs.contains(sessionID),
              !transcriptFileIsSmallEnoughForSyncDecode(parentTranscriptURL(sessionID)) else {
            return transcript(for: sessionID)
        }
        requestTranscriptLoad(for: sessionID)
        // Only defer to the spinner when the background load is actually in flight;
        // otherwise fall back so we never publish an empty snapshot with no spinner.
        guard transcriptLoadingSessionIDs.contains(sessionID) else {
            return transcript(for: sessionID)
        }
        return []
    }

    func requestSelectedTranscriptLoad() {
        guard let selectedSessionID else { return }
        requestTranscriptLoad(for: selectedSessionID)
    }

#if DEBUG
    func sidebarExpandBenchLargestParentTranscriptCandidate() -> (sessionID: UUID, fileSize: Int, loadedEntryCount: Int)? {
        sessions
            .map { session -> (sessionID: UUID, fileSize: Int, loadedEntryCount: Int) in
                let fileSize = (try? parentTranscriptURL(session.id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return (session.id, fileSize, transcriptsBySessionID[session.id]?.count ?? 0)
            }
            .max { lhs, rhs in
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize < rhs.fileSize }
                return lhs.loadedEntryCount < rhs.loadedEntryCount
            }
    }
#endif

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
        // Drain any debounced transcript writes before the index/manifest save, so all
        // on-disk pieces reflect the same in-memory state at quit time.
        flushPendingPersistTranscripts(synchronous: true)
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

    func loopRuns(for sessionID: UUID) -> [LoopRun] {
        loopRunsBySessionID[sessionID] ?? []
    }

    func activeLoopRun(for sessionID: UUID) -> LoopRun? {
        loopRuns(for: sessionID).last(where: \.isActive)
    }

    var onStopLoopRun: ((UUID, UUID) -> Void)?

    @discardableResult
    func launchSingleAgentLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool = false, executeAgent: @escaping (UUID, String, String, LoopWriteTarget, URL?, String?) async -> PiSubagentRunRecord?) async -> LoopRun? {
        guard draft.structure == .singleAgent else { return nil }
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: session.id) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: session.id)
        }
        var run = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: session.id, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)
        do { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) } catch {
            run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; upsertLoopRun(run); return nil
        }
        writeLoopProgressFile(for: run)
        let executionContext: LoopExecutionContext
        do { executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: session.projectPath, artifactDirectory: artifactDirectory) } catch let error as LoopExecutionPreparationError {
            run.status = .failed; run.endedAt = Date(); run.stopReason = error.stopReason; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run
        } catch { run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run }

        let agentName = run.makerChecker.makerName
        for iterationIndex in 1...run.maxIterations {
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let started = Date()
            run.currentIteration = iterationIndex
            upsertLoopRun(run)
            let outputPath = run.writeTarget == .artifactMarkdown ? artifactDirectory.appendingPathComponent(iterationIndex == 1 ? "single-agent-output.md" : "single-agent-output-\(iterationIndex).md").path : nil
            let task = singleAgentTask(run: run, iterationIndex: iterationIndex)
            guard let childRun = await executeAgent(run.id, agentName, task, run.writeTarget, executionContext.workingDirectory, outputPath) else {
                run.status = .failed; run.endedAt = Date(); run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let summary = childRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? childRun.error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? childRun.status.rawValue
            let timeline = [LoopTimelineEvent(step: .makerAct, roleName: agentName, note: "Child run: \(childRun.id.uuidString)", timestamp: started)]
            if childRun.status != .completed {
                let ended = Date()
                run.iterations.append(LoopIteration(index: iterationIndex, startedAt: started, endedAt: ended, summary: "Single agent stopped with \(childRun.status.rawValue): \(summary)", timeline: timeline))
                run.status = childRun.status == .stopped ? .stopped : .failed
                run.endedAt = ended
                run.stopReason = childRun.status == .stopped ? .userStopped : .agentFailed
                upsertLoopRun(run)
                return run
            }
            let validationResult = run.validationCommand.isEmpty ? nil : runValidationCommand(run.validationCommand, workingDirectory: executionContext.workingDirectory)
            let artifact = makeMarkdownArtifact(filename: iterationIndex == 1 ? "single-agent-summary.md" : "single-agent-summary-\(iterationIndex).md", markdown: singleAgentArtifactMarkdown(run: run, iterationIndex: iterationIndex, childRunID: childRun.id, summary: summary), artifactDirectory: artifactDirectory)
            let ended = Date()
            run.iterations.append(LoopIteration(index: iterationIndex, startedAt: started, endedAt: ended, summary: summary, artifacts: [artifact].compactMap { $0 }, validationResult: validationResult, timeline: timeline))
            if run.validationCommand.isEmpty { run.status = .failed; run.endedAt = ended; run.stopReason = .validationUnavailable; upsertLoopRun(run); return run }
            if validationResult?.didPass == true { run.status = .completed; run.endedAt = ended; run.stopReason = .success; upsertLoopRun(run); return run }
            upsertLoopRun(run)
        }
        run.status = .failed; run.endedAt = Date(); run.stopReason = .validationFailedAfterFinalIteration; upsertLoopRun(run); return run
    }

    @discardableResult
    func launchAgentPipelineLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool = false, executeStage: @escaping (UUID, String, String, LoopWriteTarget, URL?, String?) async -> PiSubagentRunRecord?) async -> LoopRun? {
        guard draft.structure == .agentPipeline else { return nil }
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: session.id) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: session.id)
        }

        var run = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: session.id, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)

        do {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        } catch {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = .toolFailed
            upsertLoopRun(run)
            return nil
        }
        writeLoopProgressFile(for: run)

        let executionContext: LoopExecutionContext
        do {
            executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: session.projectPath, artifactDirectory: artifactDirectory)
        } catch let error as LoopExecutionPreparationError {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = error.stopReason
            run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription, artifacts: [], validationResult: nil))
            upsertLoopRun(run)
            return run
        } catch {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = .toolFailed
            run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription))
            upsertLoopRun(run)
            return run
        }

        let validationCommand = run.validationCommand
        for iterationIndex in 1...run.maxIterations {
            let iterationStartedAt = Date()
            run.currentIteration = iterationIndex
            upsertLoopRun(run)

            var timeline: [LoopTimelineEvent] = []
            var stageSummaries: [String] = []
            var childRunIDs: [String] = []

            for (stageIndex, stageName) in run.pipeline.stageNames.enumerated() {
                if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
                let stageStartedAt = Date()
                let task = pipelineStageTask(run: run, iterationIndex: iterationIndex, stageIndex: stageIndex, stageName: stageName, previousStageSummaries: stageSummaries)
                let requestedOutputPath = run.writeTarget == .artifactMarkdown ? artifactDirectory.appendingPathComponent("stage-\(iterationIndex)-\(stageIndex + 1)-\(stageName.safeFilenameComponent)-output.md").path : nil
                guard let childRun = await executeStage(run.id, stageName, task, run.writeTarget, executionContext.workingDirectory, requestedOutputPath) else {
                    let endedAt = Date()
                    timeline.append(LoopTimelineEvent(step: .pipelineStage, roleName: stageName, note: "Pipeline stage \(stageIndex + 1) failed to launch for iteration \(iterationIndex).", timestamp: stageStartedAt))
                    run.iterations.append(LoopIteration(
                        index: iterationIndex,
                        startedAt: iterationStartedAt,
                        endedAt: endedAt,
                        summary: "Pipeline stopped because stage \(stageIndex + 1) (\(stageName)) could not be launched.",
                        artifacts: [],
                        validationResult: nil,
                        timeline: timeline
                    ))
                    run.status = .failed
                    run.endedAt = endedAt
                    run.stopReason = .agentFailed
                    upsertLoopRun(run)
                    return run
                }

                if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
                childRunIDs.append(childRun.id.uuidString)
                let summary = childRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? childRun.error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? childRun.status.rawValue
                stageSummaries.append("Stage \(stageIndex + 1) — \(stageName): \(summary)")
                let note = "Pipeline stage \(stageIndex + 1) finished with \(childRun.status.rawValue). Child run: \(childRun.id.uuidString)."
                timeline.append(LoopTimelineEvent(step: .pipelineStage, roleName: stageName, note: note, timestamp: stageStartedAt))
                upsertLoopRun(run)

                if childRun.status != .completed {
                    let endedAt = Date()
                    let artifact = makeMarkdownArtifact(
                        filename: pipelineArtifactFilename(iterationIndex: iterationIndex),
                        markdown: pipelineArtifactMarkdown(run: run, iterationIndex: iterationIndex, stageSummaries: stageSummaries, childRunIDs: childRunIDs, validationResult: nil),
                        artifactDirectory: artifactDirectory
                    )
                    run.iterations.append(LoopIteration(
                        index: iterationIndex,
                        startedAt: iterationStartedAt,
                        endedAt: endedAt,
                        summary: stageSummaries.joined(separator: "\n\n"),
                        artifacts: [artifact].compactMap { $0 },
                        validationResult: nil,
                        timeline: timeline
                    ))
                    run.status = childRun.status == .stopped ? .stopped : .failed
                    run.endedAt = endedAt
                    run.stopReason = childRun.status == .stopped ? .userStopped : .agentFailed
                    upsertLoopRun(run)
                    return run
                }
            }

            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }

            let validationResult: LoopValidationResult
            if validationCommand.isEmpty {
                validationResult = LoopValidationResult(command: "", workingDirectory: executionContext.workingDirectory?.path, exitCode: nil, duration: 0, stdout: "", stderr: "Validation command is empty.")
            } else {
                validationResult = runValidationCommand(validationCommand, workingDirectory: executionContext.workingDirectory)
            }

            let artifact = makeMarkdownArtifact(
                filename: pipelineArtifactFilename(iterationIndex: iterationIndex),
                markdown: pipelineArtifactMarkdown(run: run, iterationIndex: iterationIndex, stageSummaries: stageSummaries, childRunIDs: childRunIDs, validationResult: validationCommand.isEmpty ? nil : validationResult),
                artifactDirectory: artifactDirectory
            )
            let iterationEndedAt = Date()
            run.iterations.append(LoopIteration(
                index: iterationIndex,
                startedAt: iterationStartedAt,
                endedAt: iterationEndedAt,
                summary: stageSummaries.joined(separator: "\n\n"),
                artifacts: [artifact].compactMap { $0 },
                validationResult: validationCommand.isEmpty ? nil : validationResult,
                timeline: timeline
            ))

            if validationCommand.isEmpty {
                run.status = .failed
                run.endedAt = iterationEndedAt
                run.stopReason = .validationUnavailable
                upsertLoopRun(run)
                return run
            }
            if validationResult.didPass {
                run.status = .completed
                run.endedAt = iterationEndedAt
                run.stopReason = .success
                upsertLoopRun(run)
                return run
            }
            upsertLoopRun(run)
        }

        run.status = .failed
        run.endedAt = Date()
        run.stopReason = .validationFailedAfterFinalIteration
        upsertLoopRun(run)
        return run
    }

    @discardableResult
    func launchParallelAgentsLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool = false, executeParallel: @escaping (UUID, [(String, String)], Int, Bool) async -> PiSubagentRunRecord?) async -> LoopRun? {
        guard draft.structure == .parallelAgents else { return nil }
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: session.id) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: session.id)
        }
        var run = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: session.id, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)
        do { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) } catch {
            run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; upsertLoopRun(run); return nil
        }
        writeLoopProgressFile(for: run)
        let executionContext: LoopExecutionContext
        do { executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: session.projectPath, artifactDirectory: artifactDirectory) } catch let error as LoopExecutionPreparationError {
            run.status = .failed; run.endedAt = Date(); run.stopReason = error.stopReason; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run
        } catch { run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run }

        for iterationIndex in 1...run.maxIterations {
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let started = Date()
            run.currentIteration = iterationIndex
            upsertLoopRun(run)
            let tasks = run.parallel.branchNames.map { ($0, parallelBranchTask(run: run, iterationIndex: iterationIndex, branchName: $0)) }
            guard let graphRun = await executeParallel(run.id, tasks, max(1, min(tasks.count, tasks.count)), run.writeTarget == .newWorktree) else {
                run.status = .failed; run.endedAt = Date(); run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let summary = graphRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? graphRun.status.rawValue
            let artifact = makeMarkdownArtifact(filename: iterationIndex == 1 ? "parallel-summary.md" : "parallel-summary-\(iterationIndex).md", markdown: parallelAgentsArtifactMarkdown(run: run, iterationIndex: iterationIndex, graphRunID: graphRun.id, summary: summary), artifactDirectory: artifactDirectory)
            let validationResult = run.validationCommand.isEmpty ? nil : runValidationCommand(run.validationCommand, workingDirectory: executionContext.workingDirectory)
            let ended = Date()
            let timeline = run.parallel.branchNames.enumerated().map { offset, branch in LoopTimelineEvent(step: .parallelBranch, roleName: branch, note: "Parallel graph run: \(graphRun.id.uuidString)", timestamp: started.addingTimeInterval(TimeInterval(offset))) }
            run.iterations.append(LoopIteration(index: iterationIndex, startedAt: started, endedAt: ended, summary: summary, artifacts: [artifact].compactMap { $0 }, validationResult: validationResult, timeline: timeline))
            if graphRun.status != .completed { run.status = graphRun.status == .stopped ? .stopped : .failed; run.endedAt = ended; run.stopReason = graphRun.status == .stopped ? .userStopped : .agentFailed; upsertLoopRun(run); return run }
            if run.validationCommand.isEmpty { run.status = .failed; run.endedAt = ended; run.stopReason = .validationUnavailable; upsertLoopRun(run); return run }
            if validationResult?.didPass == true { run.status = .completed; run.endedAt = ended; run.stopReason = .success; upsertLoopRun(run); return run }
            upsertLoopRun(run)
        }
        run.status = .failed; run.endedAt = Date(); run.stopReason = .validationFailedAfterFinalIteration; upsertLoopRun(run); return run
    }

    @discardableResult
    func launchDiscoveryTriageLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool = false, executeTriage: @escaping (UUID, String, String, LoopWriteTarget, URL?, String?) async -> PiSubagentRunRecord?) async -> LoopRun? {
        guard draft.structure == .discoveryTriage else { return nil }
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: session.id) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: session.id)
        }
        var run = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: session.id, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)
        do { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) } catch {
            run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; upsertLoopRun(run); return nil
        }
        writeLoopProgressFile(for: run)
        let executionContext: LoopExecutionContext
        do { executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: session.projectPath, artifactDirectory: artifactDirectory) } catch let error as LoopExecutionPreparationError {
            run.status = .failed; run.endedAt = Date(); run.stopReason = error.stopReason; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run
        } catch { run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription)); upsertLoopRun(run); return run }

        for iterationIndex in 1...run.maxIterations {
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let started = Date()
            run.currentIteration = iterationIndex
            upsertLoopRun(run)
            let outputPath = artifactDirectory.appendingPathComponent(iterationIndex == 1 ? "discovery-triage.md" : "discovery-triage-\(iterationIndex).md").path
            let task = discoveryTriageTask(run: run, iterationIndex: iterationIndex)
            guard let childRun = await executeTriage(run.id, run.discoveryTriage.agentName, task, run.writeTarget, executionContext.workingDirectory, outputPath) else {
                run.status = .failed; run.endedAt = Date(); run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let childSummary = childRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? childRun.status.rawValue
            let artifact = makeMarkdownArtifact(filename: iterationIndex == 1 ? "discovery-triage-summary.md" : "discovery-triage-summary-\(iterationIndex).md", markdown: discoveryTriageArtifactMarkdown(run: run, iterationIndex: iterationIndex, childRunID: childRun.id, summary: childSummary), artifactDirectory: artifactDirectory)
            let validationResult = run.validationCommand.isEmpty ? nil : runValidationCommand(run.validationCommand, workingDirectory: executionContext.workingDirectory)
            let ended = Date()
            run.iterations.append(LoopIteration(index: iterationIndex, startedAt: started, endedAt: ended, summary: childSummary, artifacts: [artifact].compactMap { $0 }, validationResult: validationResult, timeline: [LoopTimelineEvent(step: .discoveryTriage, roleName: run.discoveryTriage.agentName, note: "Triage child run: \(childRun.id.uuidString)", timestamp: started)]))
            if childRun.status != .completed {
                run.status = childRun.status == .stopped ? .stopped : .failed; run.endedAt = ended; run.stopReason = childRun.status == .stopped ? .userStopped : .agentFailed; upsertLoopRun(run); return run
            }
            if run.validationCommand.isEmpty {
                run.status = .failed; run.endedAt = ended; run.stopReason = .validationUnavailable; upsertLoopRun(run); return run
            }
            if validationResult?.didPass == true {
                run.status = .completed; run.endedAt = ended; run.stopReason = .success; upsertLoopRun(run); return run
            }
            upsertLoopRun(run)
        }
        run.status = .failed; run.endedAt = Date(); run.stopReason = .validationFailedAfterFinalIteration; upsertLoopRun(run); return run
    }

    @discardableResult
    func launchMakerCheckerLoop(session: PiAgentSessionRecord, draft: LoopDraft, stopExistingActive: Bool = false, executeRole: @escaping (UUID, String, String, LoopWriteTarget, URL?, String?) async -> PiSubagentRunRecord?) async -> LoopRun? {
        guard draft.structure == .makerChecker else { return nil }
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: session.id) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: session.id)
        }

        var run = LoopRun(sessionID: session.id, projectPath: session.projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: session.id, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)
        do { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) } catch {
            run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed; upsertLoopRun(run); return nil
        }
        writeLoopProgressFile(for: run)
        let executionContext: LoopExecutionContext
        do {
            executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: session.projectPath, artifactDirectory: artifactDirectory)
        } catch let error as LoopExecutionPreparationError {
            run.status = .failed; run.endedAt = Date(); run.stopReason = error.stopReason
            run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription))
            upsertLoopRun(run); return run
        } catch {
            run.status = .failed; run.endedAt = Date(); run.stopReason = .toolFailed
            run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription))
            upsertLoopRun(run); return run
        }

        let maxLoopIterations = run.maxIterations
        var priorReview = ""
        for iterationIndex in 1...maxLoopIterations {
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let iterationStartedAt = Date()
            run.currentIteration = iterationIndex
            upsertLoopRun(run)

            let makerTask = makerCheckerTask(run: run, iterationIndex: iterationIndex, role: "Maker", priorReview: priorReview)
            let makerOutput = run.writeTarget == .artifactMarkdown ? artifactDirectory.appendingPathComponent("maker-\(iterationIndex)-output.md").path : nil
            guard let makerRun = await executeRole(run.id, run.makerChecker.makerName, makerTask, run.writeTarget, executionContext.workingDirectory, makerOutput) else {
                run.status = .failed; run.endedAt = Date(); run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            if makerRun.status != .completed {
                let ended = Date()
                run.iterations.append(LoopIteration(index: iterationIndex, startedAt: iterationStartedAt, endedAt: ended, summary: "Maker failed with \(makerRun.status.rawValue).", timeline: [LoopTimelineEvent(step: .makerAct, roleName: run.makerChecker.makerName, note: "Maker child run: \(makerRun.id.uuidString)", timestamp: iterationStartedAt)]))
                run.status = makerRun.status == .stopped ? .stopped : .failed; run.endedAt = ended; run.stopReason = makerRun.status == .stopped ? .userStopped : .agentFailed; upsertLoopRun(run); return run
            }

            let makerSummary = makerRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Maker completed."
            let checkerTask = checkerTask(run: run, iterationIndex: iterationIndex, makerSummary: makerSummary)
            let checkerOutput = artifactDirectory.appendingPathComponent("checker-\(iterationIndex)-output.md").path
            guard let checkerRun = await executeRole(run.id, run.makerChecker.checkerName, checkerTask, .artifactMarkdown, executionContext.workingDirectory, checkerOutput) else {
                run.status = .failed; run.endedAt = Date(); run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
            if let stoppedRun = stoppedLoopRun(run) { return stoppedRun }
            let checkerText = checkerRun.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? checkerRun.error?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? ""
            let ended = Date()
            if checkerRun.status != .completed {
                let timeline = [
                    LoopTimelineEvent(step: .makerAct, roleName: run.makerChecker.makerName, note: "Maker child run: \(makerRun.id.uuidString)", timestamp: iterationStartedAt),
                    LoopTimelineEvent(step: .checkerReview, roleName: run.makerChecker.checkerName, note: "Checker child run: \(checkerRun.id.uuidString) stopped with \(checkerRun.status.rawValue).", timestamp: ended)
                ]
                let statusSummary = checkerText.isEmpty ? "Checker stopped with \(checkerRun.status.rawValue)." : "Checker stopped with \(checkerRun.status.rawValue): \(checkerText)"
                run.iterations.append(LoopIteration(index: iterationIndex, startedAt: iterationStartedAt, endedAt: ended, summary: statusSummary, timeline: timeline))
                run.status = checkerRun.status == .stopped ? .stopped : .failed
                run.endedAt = ended
                run.stopReason = checkerRun.status == .stopped ? .userStopped : .agentFailed
                upsertLoopRun(run)
                return run
            }
            let checkerResult = checkerResult(from: checkerText, fallbackRubric: run.makerChecker.checkerRubric)
            let iterationSummary = checkerIterationSummary(result: checkerResult, checkerText: checkerText)
            let validationResult = run.validationCommand.isEmpty ? nil : runValidationCommand(run.validationCommand, workingDirectory: executionContext.workingDirectory)
            let timeline = [
                LoopTimelineEvent(step: .makerAct, roleName: run.makerChecker.makerName, note: "Maker child run: \(makerRun.id.uuidString)", timestamp: iterationStartedAt),
                LoopTimelineEvent(step: .checkerReview, roleName: run.makerChecker.checkerName, note: "Checker child run: \(checkerRun.id.uuidString) returned \(checkerResult.displayName).", timestamp: ended)
            ]
            run.iterations.append(LoopIteration(index: iterationIndex, startedAt: iterationStartedAt, endedAt: ended, summary: iterationSummary, validationResult: validationResult, checkerResult: checkerResult, timeline: timeline))
            priorReview = checkerText
            switch checkerResult {
            case .approve:
                run.status = .completed; run.endedAt = ended; run.stopReason = .success; upsertLoopRun(run); return run
            case .reject:
                upsertLoopRun(run); continue
            case .askHuman:
                run.status = .stopped; run.endedAt = ended; run.stopReason = .humanInputRequired; upsertLoopRun(run); return run
            case .fail:
                run.status = .failed; run.endedAt = ended; run.stopReason = .agentFailed; upsertLoopRun(run); return run
            }
        }
        run.status = .completed; run.endedAt = Date(); run.stopReason = .maxIterationsReached; upsertLoopRun(run); return run
    }

    @discardableResult
    func launchSmokeLoop(sessionID: UUID, projectPath: String?, draft: LoopDraft, stopExistingActive: Bool = false) -> LoopRun? {
        guard !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let active = activeLoopRun(for: sessionID) {
            guard stopExistingActive else { return nil }
            stopLoopRun(active.id, sessionID: sessionID)
        }

        var run = LoopRun(sessionID: sessionID, projectPath: projectPath, draft: draft)
        let artifactDirectory = loopArtifactDirectoryURL(sessionID: sessionID, runID: run.id)
        run.artifactDirectoryPath = artifactDirectory.path
        upsertLoopRun(run)

        do {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        } catch {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = .toolFailed
            upsertLoopRun(run)
            return nil
        }
        writeLoopProgressFile(for: run)

        let executionContext: LoopExecutionContext
        do {
            executionContext = try prepareLoopExecutionContext(writeTarget: run.writeTarget, projectPath: projectPath, artifactDirectory: artifactDirectory)
        } catch let error as LoopExecutionPreparationError {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = error.stopReason
            run.iterations.append(LoopIteration(
                index: 0,
                summary: error.localizedDescription,
                artifacts: [],
                validationResult: nil
            ))
            upsertLoopRun(run)
            return run
        } catch {
            run.status = .failed
            run.endedAt = Date()
            run.stopReason = .toolFailed
            run.iterations.append(LoopIteration(index: 0, summary: error.localizedDescription))
            upsertLoopRun(run)
            return run
        }

        if run.structure == .humanApproval {
            let now = Date()
            let artifact = makeMarkdownArtifact(
                filename: "human-approval-checkpoint.md",
                markdown: "# Human Approval Checkpoint\n\nGoal: \(run.goal)\n\nCheckpoint: \(run.humanApproval.checkpointPrompt)\n\nStatus: Waiting for human input.",
                artifactDirectory: artifactDirectory
            )
            guard let artifact else {
                run.status = .failed
                run.endedAt = now
                run.stopReason = .toolFailed
                upsertLoopRun(run)
                return nil
            }
            run.currentIteration = 1
            run.iterations.append(LoopIteration(
                index: 1,
                startedAt: now,
                endedAt: now,
                summary: "Stopped at human approval checkpoint.",
                artifacts: [artifact],
                timeline: [LoopTimelineEvent(step: .humanApprovalCheckpoint, roleName: "Human Approval", note: run.humanApproval.checkpointPrompt, timestamp: now)]
            ))
            run.status = .stopped
            run.endedAt = now
            run.stopReason = .humanInputRequired
            upsertLoopRun(run)
            return run
        }

        let validationCommand = run.validationCommand
        let maxLoopIterations = run.maxIterations
        for iterationIndex in 1...maxLoopIterations {
            let iterationStartedAt = Date()
            var artifacts: [LoopArtifact] = []
            var changedFiles: [String] = []

            switch run.writeTarget {
            case .artifactMarkdown:
                let filename: String
                let markdown: String
                switch run.structure {
                case .discoveryTriage:
                    filename = iterationIndex == 1 ? "discovery-triage.md" : "discovery-triage-\(iterationIndex).md"
                    markdown = "# Discovery / Triage\n\nGoal: \(run.goal)\n\nClassification: \(run.discoveryTriage.classificationPrompt)\n\nSummary: Deterministic triage preview classified the input and recommends a focused follow-up."
                case .agentPipeline:
                    filename = iterationIndex == 1 ? "pipeline-summary.md" : "pipeline-summary-\(iterationIndex).md"
                    markdown = "# Agent Pipeline Summary\n\nGoal: \(run.goal)\n\nStages: \(run.pipeline.stageNames.joined(separator: " → "))\n\nResult: Deterministic pipeline preview completed the ordered handoff."
                case .parallelAgents:
                    filename = iterationIndex == 1 ? "parallel-summary.md" : "parallel-summary-\(iterationIndex).md"
                    markdown = "# Parallel Agents Summary\n\nGoal: \(run.goal)\n\nBranches: \(run.parallel.branchNames.joined(separator: ", "))\n\nResult: Deterministic parallel preview compared branch outputs."
                default:
                    filename = iterationIndex == 1 ? "loop-smoke.md" : "loop-smoke-\(iterationIndex).md"
                    markdown = "# Loop Smoke Output\n\nGoal: \(run.goal)\n\nIteration: \(iterationIndex)\n\nResult: Artifact smoke fixture completed."
                }
                guard let artifact = makeMarkdownArtifact(filename: filename, markdown: markdown, artifactDirectory: artifactDirectory) else {
                    run.status = .failed
                    run.endedAt = Date()
                    run.stopReason = .toolFailed
                    upsertLoopRun(run)
                    return nil
                }
                artifacts = [artifact]
            case .newWorktree, .currentCheckout:
                do {
                    guard let workingDirectory = executionContext.workingDirectory else {
                        run.status = .failed
                        run.endedAt = Date()
                        run.stopReason = .unsafeWriteTarget
                        upsertLoopRun(run)
                        return run
                    }
                    let smokeURL = workingDirectory.appendingPathComponent("loop-smoke-write-target.txt", isDirectory: false)
                    let text = "Loop smoke write target\nRun: \(run.id.uuidString)\nIteration: \(iterationIndex)\nTarget: \(run.writeTarget.rawValue)\n"
                    try text.write(to: smokeURL, atomically: true, encoding: .utf8)
                    changedFiles = ["loop-smoke-write-target.txt"]
                } catch {
                    run.status = .failed
                    run.endedAt = Date()
                    run.stopReason = .toolFailed
                    upsertLoopRun(run)
                    return nil
                }
            }

            let validationResult: LoopValidationResult
            if validationCommand.isEmpty {
                validationResult = LoopValidationResult(
                    command: "",
                    workingDirectory: executionContext.workingDirectory?.path,
                    exitCode: nil,
                    duration: 0,
                    stdout: "",
                    stderr: "Validation command is empty."
                )
            } else {
                validationResult = runValidationCommand(validationCommand, workingDirectory: executionContext.workingDirectory)
            }

            let iterationEndedAt = Date()
            run.currentIteration = iterationIndex

            if run.structure == .agentPipeline {
                let timeline = run.pipeline.stageNames.enumerated().map { offset, stage in
                    LoopTimelineEvent(step: .pipelineStage, roleName: stage, note: "Pipeline stage \(offset + 1) completed for iteration \(iterationIndex).", timestamp: iterationStartedAt.addingTimeInterval(TimeInterval(offset)))
                }
                run.iterations.append(LoopIteration(
                    index: iterationIndex,
                    startedAt: iterationStartedAt,
                    endedAt: iterationEndedAt,
                    summary: "Pipeline completed stages: \(run.pipeline.stageNames.joined(separator: " → ")).",
                    artifacts: artifacts,
                    validationResult: validationCommand.isEmpty ? nil : validationResult,
                    timeline: timeline,
                    changedFiles: changedFiles
                ))
                if validationCommand.isEmpty {
                    run.status = .failed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .validationUnavailable
                    upsertLoopRun(run)
                    return run
                }
                if validationResult.didPass {
                    run.status = .completed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .success
                    upsertLoopRun(run)
                    return run
                }
                upsertLoopRun(run)
                continue
            }

            if run.structure == .parallelAgents {
                let timeline = run.parallel.branchNames.enumerated().map { offset, branch in
                    LoopTimelineEvent(step: .parallelBranch, roleName: branch, note: "Parallel branch \(offset + 1) completed for iteration \(iterationIndex).", timestamp: iterationStartedAt.addingTimeInterval(TimeInterval(offset)))
                }
                run.iterations.append(LoopIteration(
                    index: iterationIndex,
                    startedAt: iterationStartedAt,
                    endedAt: iterationEndedAt,
                    summary: "Parallel preview completed branches: \(run.parallel.branchNames.joined(separator: ", ")).",
                    artifacts: artifacts,
                    validationResult: validationCommand.isEmpty ? nil : validationResult,
                    timeline: timeline,
                    changedFiles: changedFiles
                ))
                if validationCommand.isEmpty {
                    run.status = .failed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .validationUnavailable
                    upsertLoopRun(run)
                    return run
                }
                if validationResult.didPass {
                    run.status = .completed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .success
                    upsertLoopRun(run)
                    return run
                }
                upsertLoopRun(run)
                continue
            }

            if run.structure == .discoveryTriage {
                let timeline = [LoopTimelineEvent(step: .discoveryTriage, roleName: "Triage", note: run.discoveryTriage.classificationPrompt, timestamp: iterationEndedAt)]
                run.iterations.append(LoopIteration(
                    index: iterationIndex,
                    startedAt: iterationStartedAt,
                    endedAt: iterationEndedAt,
                    summary: "Discovery/triage classification artifact recorded.",
                    artifacts: artifacts,
                    validationResult: validationCommand.isEmpty ? nil : validationResult,
                    timeline: timeline,
                    changedFiles: changedFiles
                ))
                if validationCommand.isEmpty {
                    run.status = .failed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .validationUnavailable
                    upsertLoopRun(run)
                    return run
                }
                if validationResult.didPass {
                    run.status = .completed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .success
                    upsertLoopRun(run)
                    return run
                }
                upsertLoopRun(run)
                continue
            }

            if run.structure == .makerChecker {
                let checkerResult = deterministicCheckerResult(
                    rubric: run.makerChecker.checkerRubric,
                    validationResult: validationCommand.isEmpty ? nil : validationResult,
                    iterationIndex: iterationIndex
                )
                let timeline = [
                    LoopTimelineEvent(step: .makerAct, roleName: run.makerChecker.makerName, note: "Maker act step completed for iteration \(iterationIndex).", timestamp: iterationStartedAt),
                    LoopTimelineEvent(step: .checkerReview, roleName: run.makerChecker.checkerName, note: "Report-only checker returned \(checkerResult.displayName).", timestamp: iterationEndedAt)
                ]
                run.iterations.append(LoopIteration(
                    index: iterationIndex,
                    startedAt: iterationStartedAt,
                    endedAt: iterationEndedAt,
                    summary: "Report-only checker returned \(checkerResult.displayName).",
                    artifacts: artifacts,
                    validationResult: validationCommand.isEmpty ? nil : validationResult,
                    checkerResult: checkerResult,
                    timeline: timeline,
                    changedFiles: changedFiles
                ))

                switch checkerResult {
                case .approve:
                    run.status = .completed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .success
                    upsertLoopRun(run)
                    return run
                case .reject:
                    upsertLoopRun(run)
                    continue
                case .askHuman:
                    run.status = .stopped
                    run.endedAt = iterationEndedAt
                    run.stopReason = .humanInputRequired
                    upsertLoopRun(run)
                    return run
                case .fail:
                    run.status = .failed
                    run.endedAt = iterationEndedAt
                    run.stopReason = .agentFailed
                    upsertLoopRun(run)
                    return run
                }
            }

            run.iterations.append(LoopIteration(
                index: iterationIndex,
                startedAt: iterationStartedAt,
                endedAt: iterationEndedAt,
                summary: validationResult.didPass ? "Validation passed." : "Validation did not pass.",
                artifacts: artifacts,
                validationResult: validationResult,
                changedFiles: changedFiles
            ))

            if validationCommand.isEmpty {
                run.status = .failed
                run.endedAt = iterationEndedAt
                run.stopReason = .validationUnavailable
                upsertLoopRun(run)
                return run
            }

            if validationResult.didPass {
                run.status = .completed
                run.endedAt = iterationEndedAt
                run.stopReason = .success
                upsertLoopRun(run)
                return run
            }

            upsertLoopRun(run)
        }

        run.status = run.structure == .makerChecker ? .completed : .failed
        run.endedAt = Date()
        run.stopReason = run.structure == .makerChecker ? .maxIterationsReached : .validationFailedAfterFinalIteration
        upsertLoopRun(run)
        return run
    }

    private func stoppedLoopRun(_ run: LoopRun) -> LoopRun? {
        guard let current = loopRunsBySessionID[run.sessionID]?.first(where: { $0.id == run.id }), !current.isActive else { return nil }
        return current
    }

    private func loopRuntimeContext(run: LoopRun, iterationIndex: Int) -> [String] {
        var lines = [
            "Agent Deck is running this loop. Agent Deck controls iteration count, retries, stopping, artifacts, and validation. Do not run your own open-ended loop; complete only this assigned step.",
            "Loop goal: \(run.goal)",
            "Iteration: \(iterationIndex) of \(run.maxIterations)",
            "Write target: \(run.writeTarget.displayName)"
        ]
        if let launchContext = launchContextForPrompt(run: run, iterationIndex: iterationIndex) {
            lines.append("Launch context (\(run.launchContextScope.displayName.lowercased())):\n\(launchContext)")
        }
        lines.append(sharedLoopProgressPromptSection(for: run))
        return lines
    }

    private func launchContextForPrompt(run: LoopRun, iterationIndex: Int) -> String? {
        guard let launchContext = run.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines), !launchContext.isEmpty else { return nil }
        switch run.launchContextScope {
        case .firstIterationOnly:
            return iterationIndex == 1 ? launchContext : nil
        case .everyIteration:
            return launchContext
        }
    }

    private func pipelineStageTask(run: LoopRun, iterationIndex: Int, stageIndex: Int, stageName: String, previousStageSummaries: [String]) -> String {
        var lines: [String] = loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are completing stage \(stageIndex + 1) of \(run.pipeline.stageNames.count) in an ordered pipeline.",
            "Assigned stage/agent: \(stageName)",
            "Pipeline order: \(run.pipeline.stageNames.joined(separator: " → "))"
        ]
        if !run.validationCommand.isEmpty {
            lines.append("Validation after the final stage: \(run.validationCommand)")
        }
        if !previousStageSummaries.isEmpty {
            lines.append("")
            lines.append("Previous stage handoff summaries:")
            lines.append(contentsOf: previousStageSummaries.map { "- \($0)" })
        }
        lines.append("")
        lines.append("Do only the work appropriate for this assigned stage. Be explicit about what you changed, found, or verified. End with a concise handoff summary for the next stage or final loop summary.")
        return lines.joined(separator: "\n")
    }

    private func pipelineArtifactFilename(iterationIndex: Int) -> String {
        iterationIndex == 1 ? "pipeline-summary.md" : "pipeline-summary-\(iterationIndex).md"
    }

    private func pipelineArtifactMarkdown(run: LoopRun, iterationIndex: Int, stageSummaries: [String], childRunIDs: [String], validationResult: LoopValidationResult?) -> String {
        var lines: [String] = [
            "# Agent Pipeline Summary",
            "",
            "Goal: \(run.goal)",
            "",
            "Iteration: \(iterationIndex)",
            "Stages: \(run.pipeline.stageNames.joined(separator: " → "))",
            "",
            "## Child runs"
        ]
        if childRunIDs.isEmpty {
            lines.append("No child runs recorded.")
        } else {
            lines.append(contentsOf: childRunIDs.map { "- \($0)" })
        }
        lines.append("")
        lines.append("## Stage handoffs")
        if stageSummaries.isEmpty {
            lines.append("No stage summaries recorded.")
        } else {
            lines.append(contentsOf: stageSummaries.map { "- \($0)" })
        }
        if let validationResult {
            lines.append("")
            lines.append("## Validation")
            lines.append("Command: \(validationResult.command)")
            lines.append("Exit code: \(validationResult.exitCode.map(String.init) ?? "unavailable")")
            if !validationResult.stdout.isEmpty {
                lines.append("")
                lines.append("### stdout")
                lines.append("```")
                lines.append(validationResult.stdout)
                lines.append("```")
            }
            if !validationResult.stderr.isEmpty {
                lines.append("")
                lines.append("### stderr")
                lines.append("```")
                lines.append(validationResult.stderr)
                lines.append("```")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func makeMarkdownArtifact(filename: String, markdown: String, artifactDirectory: URL) -> LoopArtifact? {
        let artifactURL = artifactDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try markdown.write(to: artifactURL, atomically: true, encoding: .utf8)
            return LoopArtifact(filename: filename, markdown: markdown, filePath: artifactURL.path)
        } catch {
            return nil
        }
    }

    private func singleAgentTask(run: LoopRun, iterationIndex: Int) -> String {
        (loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are completing one implementation/review pass for this loop.",
            "Complete the requested work within the selected write target. End with a concise summary of changes, evidence, risks, and next steps."
        ]).joined(separator: "\n\n")
    }

    private func singleAgentArtifactMarkdown(run: LoopRun, iterationIndex: Int, childRunID: UUID, summary: String) -> String {
        """
        # Single Agent Summary

        Goal: \(run.goal)

        Iteration: \(iterationIndex)
        Agent: \(run.makerChecker.makerName)
        Child run: \(childRunID.uuidString)

        Summary:
        \(summary)
        """
    }

    private func parallelBranchTask(run: LoopRun, iterationIndex: Int, branchName: String) -> String {
        (loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are working on one assigned branch/hypothesis of a parallel loop.",
            "Assigned branch/agent: \(branchName)",
            "Work independently on this branch. Do not coordinate with sibling branches unless the task explicitly asks you to. End with a concise Markdown summary of findings, changes, risks, and recommended next action."
        ]).joined(separator: "\n\n")
    }

    private func parallelAgentsArtifactMarkdown(run: LoopRun, iterationIndex: Int, graphRunID: UUID, summary: String) -> String {
        """
        # Parallel Agents Summary

        Goal: \(run.goal)

        Iteration: \(iterationIndex)
        Branches: \(run.parallel.branchNames.joined(separator: ", "))
        Parallel graph run: \(graphRunID.uuidString)

        Summary:
        \(summary)
        """
    }

    private func discoveryTriageTask(run: LoopRun, iterationIndex: Int) -> String {
        (loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are performing discovery and triage for this loop step.",
            "Classification prompt: \(run.discoveryTriage.classificationPrompt)",
            "Inspect the requested signals and repository context. Group findings by severity/category, cite evidence, and recommend the safest next action. Do not implement fixes unless the loop goal explicitly asks you to. Produce a concise Markdown triage artifact."
        ]).joined(separator: "\n\n")
    }

    private func discoveryTriageArtifactMarkdown(run: LoopRun, iterationIndex: Int, childRunID: UUID, summary: String) -> String {
        """
        # Discovery / Triage

        Goal: \(run.goal)

        Iteration: \(iterationIndex)
        Agent: \(run.discoveryTriage.agentName)
        Child run: \(childRunID.uuidString)

        Classification prompt: \(run.discoveryTriage.classificationPrompt)

        Summary: \(summary)
        """
    }

    private func makerCheckerTask(run: LoopRun, iterationIndex: Int, role: String, priorReview: String) -> String {
        var lines = loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are implementing one maker pass for this loop step."
        ]
        if !priorReview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Previous checker review to address:\n\(priorReview)")
        }
        lines.append("Do only the requested work for this maker pass. End with a concise summary for the reviewer/checker, including what changed, what evidence you used, and what remains.")
        return lines.joined(separator: "\n\n")
    }

    private func checkerTask(run: LoopRun, iterationIndex: Int, makerSummary: String) -> String {
        (loopRuntimeContext(run: run, iterationIndex: iterationIndex) + [
            "You are reviewing one completed loop iteration. Review only; do not edit project files.",
            "Review criteria: \(run.makerChecker.checkerRubric)",
            "Maker summary:\n\(makerSummary)",
            "Agent Deck parses your first line to decide the next step. Start your final response with exactly one decision line: APPROVE, REJECT, ASK_HUMAN, or FAIL. Then provide a concise Markdown recap/rationale with concrete evidence: what changed, whether it meets the rubric, remaining risks, and the next action."
        ]).joined(separator: "\n\n")
    }

    private func checkerIterationSummary(result: LoopCheckerResult, checkerText: String) -> String {
        let rationale = checkerRationale(from: checkerText).nonEmpty ?? checkerText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var lines = ["Checker outcome: \(result.displayName)"]
        if let rationale {
            lines.append(rationale)
        }
        return lines.joined(separator: "\n")
    }

    private func checkerRationale(from text: String) -> String {
        var lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        guard let first = lines.first else { return "" }
        let decision = first
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.-—– "))
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if ["approve", "reject", "ask_human", "fail"].contains(decision) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkerResult(from text: String, fallbackRubric: String) -> LoopCheckerResult {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let normalizedDecisionLine = firstLine.lowercased().replacingOccurrences(of: "-", with: "_")
        if normalizedDecisionLine.contains("ask_human") || normalizedDecisionLine.contains("ask human") { return .askHuman }
        if normalizedDecisionLine.contains("fail") { return .fail }
        if normalizedDecisionLine.contains("reject") { return .reject }
        if normalizedDecisionLine.contains("approve") { return .approve }
        return deterministicCheckerResult(rubric: fallbackRubric, validationResult: nil, iterationIndex: 1)
    }

    private func deterministicCheckerResult(rubric: String, validationResult: LoopValidationResult?, iterationIndex: Int) -> LoopCheckerResult {
        let normalized = rubric.lowercased().replacingOccurrences(of: "-", with: " ")
        if normalized.contains("ask human") || normalized.contains("askhuman") { return .askHuman }
        if normalized.contains("fail") { return .fail }
        if normalized.contains("reject once") { return iterationIndex == 1 ? .reject : .approve }
        if normalized.contains("reject") && !normalized.contains("approve") { return .reject }
        if normalized.contains("approve") { return .approve }
        if let validationResult { return validationResult.didPass ? .approve : .reject }
        return .approve
    }

    private struct LoopExecutionContext {
        let workingDirectory: URL?
    }

    private struct LoopExecutionPreparationError: LocalizedError {
        let stopReason: LoopStopReason
        let message: String

        var errorDescription: String? { message }
    }

    private func prepareLoopExecutionContext(writeTarget: LoopWriteTarget, projectPath: String?, artifactDirectory: URL) throws -> LoopExecutionContext {
        switch writeTarget {
        case .artifactMarkdown:
            return LoopExecutionContext(workingDirectory: validationWorkingDirectory(projectPath: projectPath))
        case .currentCheckout:
            guard let workingDirectory = validationWorkingDirectory(projectPath: projectPath) else {
                throw LoopExecutionPreparationError(stopReason: .unsafeWriteTarget, message: "Current checkout target requires an existing project directory.")
            }
            return LoopExecutionContext(workingDirectory: workingDirectory)
        case .newWorktree:
            guard let projectDirectory = validationWorkingDirectory(projectPath: projectPath) else {
                throw LoopExecutionPreparationError(stopReason: .unsafeWriteTarget, message: "Worktree target requires an existing project directory.")
            }
            let worktreeURL = artifactDirectory.appendingPathComponent("worktree", isDirectory: true)
            try? FileManager.default.removeItem(at: worktreeURL)
            let repositoryCheck = runGitSynchronously(["-C", projectDirectory.path, "rev-parse", "--is-inside-work-tree"], currentDirectory: nil, timeout: 15)
            guard repositoryCheck.exitCode == 0, repositoryCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                throw LoopExecutionPreparationError(stopReason: .unsafeWriteTarget, message: "Worktree target requires a git repository.")
            }
            let result = runGitSynchronously(["-C", projectDirectory.path, "worktree", "add", "--detach", worktreeURL.path, "HEAD"], currentDirectory: nil, timeout: 60)
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LoopExecutionPreparationError(stopReason: .toolFailed, message: detail.isEmpty ? "git worktree add failed." : detail)
            }
            return LoopExecutionContext(workingDirectory: worktreeURL)
        }
    }

    private func validationWorkingDirectory(projectPath: String?) -> URL? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: projectPath, isDirectory: true)
    }

    private func runValidationCommand(_ command: String, workingDirectory: URL?) -> LoopValidationResult {
        let startedAt = Date()
        let outputDirectory = fileURL.deletingLastPathComponent().appendingPathComponent("loop-validation-output", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("\(UUID().uuidString)-stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("\(UUID().uuidString)-stderr.txt")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let process = Process()
            let terminationSemaphore = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            process.terminationHandler = { _ in terminationSemaphore.signal() }
            try process.run()
            let timedOut = terminationSemaphore.wait(timeout: .now() + 30) == .timedOut
            if timedOut {
                process.terminate()
                process.waitUntilExit()
            }

            var stderr = cappedText(at: stderrURL)
            if timedOut {
                stderr += stderr.isEmpty ? "Validation command timed out after 30 seconds." : "\nValidation command timed out after 30 seconds."
            }
            return LoopValidationResult(
                command: command,
                workingDirectory: workingDirectory?.path,
                exitCode: timedOut ? nil : Int(process.terminationStatus),
                duration: Date().timeIntervalSince(startedAt),
                stdout: cappedText(at: stdoutURL),
                stderr: stderr,
                stdoutPath: stdoutURL.path,
                stderrPath: stderrURL.path
            )
        } catch {
            return LoopValidationResult(
                command: command,
                workingDirectory: workingDirectory?.path,
                exitCode: nil,
                duration: Date().timeIntervalSince(startedAt),
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }

    private func runGitSynchronously(_ arguments: [String], currentDirectory: URL?, timeout: TimeInterval) -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in terminationSemaphore.signal() }
        do {
            try process.run()
            let timedOut = terminationSemaphore.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                process.waitUntilExit()
                return CommandResult(stdout: "", stderr: "git command timed out after \(Int(timeout)) seconds.", exitCode: -1)
            }
            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
    }

    private func cappedText(at url: URL, byteLimit: Int = 16 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit + 1)) ?? Data()
        let capped = data.count > byteLimit ? data.prefix(byteLimit) : data[...]
        var text = String(decoding: capped, as: UTF8.self)
        if data.count > byteLimit {
            text += "\n… output truncated …"
        }
        return text
    }

    private static let loopProgressFilename = "loop-progress.md"
    private static let loopProgressSummaryLimit = 420
    private static let loopProgressLineLimit = 180
    private static let loopProgressRoundNoteLimit = 6

    private func loopProgressFileURL(for run: LoopRun) -> URL? {
        guard let artifactDirectoryPath = run.artifactDirectoryPath else { return nil }
        return URL(fileURLWithPath: artifactDirectoryPath, isDirectory: true)
            .appendingPathComponent(Self.loopProgressFilename, isDirectory: false)
    }

    private func writeLoopProgressFile(for run: LoopRun) {
        guard let fileURL = loopProgressFileURL(for: run) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        try? loopProgressMarkdown(for: run).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loopProgressMarkdownForRecap(_ run: LoopRun) -> String {
        if let fileURL = loopProgressFileURL(for: run),
           let text = try? String(contentsOf: fileURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return loopProgressMarkdown(for: run)
    }

    private func sharedLoopProgressPromptSection(for run: LoopRun) -> String {
        let progressText = loopProgressMarkdownForRecap(run)
        return """
        Shared loop progress file:
        Agent Deck maintains `\(Self.loopProgressFilename)` in this loop's artifact directory as the shared short-term markdown memory for all loop agents. Do not edit that file directly. Read and use the full current contents below to build on prior evidence, avoid repeating failed approaches, and hand off concise findings in your final response so Agent Deck can refresh the file after this round.

        ```markdown
        \(progressText)
        ```
        """
    }

    private func loopProgressMarkdown(for run: LoopRun) -> String {
        var sections: [(String, [String])] = []
        sections.append(("Goal", [boundedLine(run.goal, fallback: "Not specified.")]))
        if let launchContext = run.launchContext?.trimmingCharacters(in: .whitespacesAndNewlines), !launchContext.isEmpty {
            sections.append(("Launch Context Notes", [boundedSummary(launchContext, fallback: "Custom launch context was provided.")]))
        }
        sections.append(("Current Understanding", [currentLoopUnderstanding(for: run)]))
        sections.append(("What Worked", loopProgressWorkedLines(for: run)))
        sections.append(("What Did Not Work", loopProgressDidNotWorkLines(for: run)))
        sections.append(("Current Evidence", loopProgressEvidenceLines(for: run)))
        sections.append(("Avoid Repeating", loopProgressAvoidRepeatingLines(for: run)))
        sections.append(("Next Recommended Move", [loopProgressNextMove(for: run)]))
        sections.append(("Round Notes", loopProgressRoundNotes(for: run)))

        var lines: [String] = []
        for (title, bodyLines) in sections {
            lines.append("## \(title)")
            let normalized = bodyLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if normalized.isEmpty {
                lines.append("- None yet.")
            } else {
                lines.append(contentsOf: normalized)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func currentLoopUnderstanding(for run: LoopRun) -> String {
        if let last = run.iterations.last(where: { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "- Latest: \(boundedSummary(last.summary))"
        }
        return "- Not established yet."
    }

    private func loopProgressWorkedLines(for run: LoopRun) -> [String] {
        var lines: [String] = []
        for iteration in run.iterations.suffix(Self.loopProgressRoundNoteLimit) {
            if iteration.checkerResult == .approve {
                lines.append("- Round \(iteration.index): checker approved.")
            }
            if iteration.validationResult?.didPass == true {
                lines.append("- Round \(iteration.index): validation passed.")
            }
            if run.structure != .makerChecker && iteration.validationResult == nil && !iteration.summary.isEmpty && iteration.endedAt != nil {
                lines.append("- Round \(iteration.index): \(boundedSummary(iteration.summary))")
            }
        }
        return Array(lines.prefix(Self.loopProgressRoundNoteLimit))
    }

    private func loopProgressDidNotWorkLines(for run: LoopRun) -> [String] {
        var lines: [String] = []
        for iteration in run.iterations.suffix(Self.loopProgressRoundNoteLimit) {
            if let checkerResult = iteration.checkerResult, checkerResult != .approve {
                lines.append("- Round \(iteration.index): checker \(checkerResult.displayName.lowercased()) — \(boundedSummary(iteration.summary))")
            }
            if let validation = iteration.validationResult, !validation.didPass {
                lines.append("- Round \(iteration.index): validation failed\(validation.exitCode.map { " (exit \($0))" } ?? "") — \(boundedSummary(validation.stderr.nonEmpty ?? validation.stdout.nonEmpty ?? iteration.summary))")
            }
        }
        if !run.isActive, let stopReason = run.stopReason, stopReason != .success, stopReason != .maxIterationsReached {
            lines.append("- Loop stopped: \(stopReason.displayName).")
        }
        return Array(lines.prefix(Self.loopProgressRoundNoteLimit))
    }

    private func loopProgressEvidenceLines(for run: LoopRun) -> [String] {
        var lines: [String] = []
        if let artifactDirectoryPath = run.artifactDirectoryPath {
            lines.append("- Artifact directory: \(artifactDirectoryPath)")
            lines.append("- Shared progress artifact: \(Self.loopProgressFilename)")
        }
        if let validation = run.iterations.last?.validationResult {
            lines.append("- Latest validation: \(validation.didPass ? "passed" : "failed")\(validation.exitCode.map { " (exit \($0))" } ?? "") via `\(boundedLine(validation.command, fallback: "validation"))`.")
        }
        let artifacts = run.iterations.flatMap(\.artifacts).suffix(4).map(\.filename)
        if !artifacts.isEmpty {
            lines.append("- Recent artifacts: \(artifacts.joined(separator: ", ")).")
        }
        let changedFiles = run.iterations.flatMap(\.changedFiles).suffix(6)
        if !changedFiles.isEmpty {
            lines.append("- Changed files: \(changedFiles.joined(separator: ", ")).")
        }
        if let stopReason = run.stopReason {
            lines.append("- Current loop outcome: \(run.displayStatusName), stop reason \(stopReason.displayName).")
        }
        return lines
    }

    private func loopProgressAvoidRepeatingLines(for run: LoopRun) -> [String] {
        let rejected = run.iterations.filter { $0.checkerResult == .reject }.suffix(3)
        var lines = rejected.map { "- Do not repeat Round \($0.index) rejection cause: \(boundedSummary($0.summary))" }
        let failedValidation = run.iterations.filter { $0.validationResult?.didPass == false }.suffix(3)
        lines.append(contentsOf: failedValidation.map { iteration in
            let detail = iteration.validationResult?.stderr.nonEmpty ?? iteration.validationResult?.stdout.nonEmpty ?? iteration.summary
            return "- Do not ignore failed validation from Round \(iteration.index): \(boundedSummary(detail))"
        })
        return Array(lines.prefix(Self.loopProgressRoundNoteLimit))
    }

    private func loopProgressNextMove(for run: LoopRun) -> String {
        if run.isActive {
            if let last = run.iterations.last, last.checkerResult == .reject {
                return "- Address the latest checker rejection with the smallest targeted change and cite fresh evidence."
            }
            if run.iterations.last?.validationResult?.didPass == false {
                return "- Fix the latest validation failure first, then rerun the configured validation."
            }
            return "- Continue the assigned loop step and produce concise evidence for Agent Deck to merge."
        }
        switch run.stopReason {
        case .success:
            return "- No further loop move required unless the user asks for follow-up."
        case .maxIterationsReached:
            return "- Escalate or revise strategy before another run; all configured iterations were used."
        case .validationUnavailable:
            return "- Provide or choose a validation command before retrying."
        case .validationFailedAfterFinalIteration:
            return "- Inspect the last validation failure and retry with a narrower fix."
        case .humanInputRequired:
            return "- Wait for human approval or direction."
        case .humanRejected:
            return "- Do not continue without revised human direction."
        case .agentFailed, .toolFailed, .appInterrupted, .userStopped, .unsafeWriteTarget, .none:
            return "- Review the stop reason and decide whether a safe retry is appropriate."
        }
    }

    private func loopProgressRoundNotes(for run: LoopRun) -> [String] {
        let notes = run.iterations.suffix(Self.loopProgressRoundNoteLimit).map { iteration -> String in
            var parts = ["- Round \(iteration.index): \(boundedSummary(iteration.summary, fallback: "No summary."))"]
            if let checkerResult = iteration.checkerResult {
                parts.append("checker \(checkerResult.displayName.lowercased())")
            }
            if let validation = iteration.validationResult {
                parts.append("validation \(validation.didPass ? "passed" : "failed")\(validation.exitCode.map { " exit \($0)" } ?? "")")
            }
            if !iteration.changedFiles.isEmpty {
                parts.append("changed \(iteration.changedFiles.prefix(4).joined(separator: ", "))")
            }
            if !iteration.artifacts.isEmpty {
                parts.append("artifacts \(iteration.artifacts.prefix(3).map(\.filename).joined(separator: ", "))")
            }
            return parts.joined(separator: "; ")
        }
        return notes.isEmpty ? ["- No rounds completed yet."] : notes
    }

    private func boundedSummary(_ text: String, fallback: String = "None.") -> String {
        let compact = text
            .replacingOccurrences(of: "```", with: "'''")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compact.isEmpty else { return fallback }
        return String(compact.prefix(Self.loopProgressSummaryLimit)) + (compact.count > Self.loopProgressSummaryLimit ? "…" : "")
    }

    private func boundedLine(_ text: String, fallback: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return fallback }
        return String(compact.prefix(Self.loopProgressLineLimit)) + (compact.count > Self.loopProgressLineLimit ? "…" : "")
    }

    private func loopArtifactDirectoryURL(sessionID: UUID, runID: UUID) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("loop-artifacts", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    @discardableResult
    func stopLoopRun(_ runID: UUID, sessionID: UUID) -> LoopRun? {
        guard var runs = loopRunsBySessionID[sessionID], let index = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        var run = runs[index]
        guard run.isActive else { return run }
        run.status = .stopped
        run.endedAt = Date()
        run.stopReason = .userStopped
        onStopLoopRun?(runID, sessionID)
        runs[index] = run
        loopRunsBySessionID[sessionID] = runs
        writeLoopProgressFile(for: run)
        upsert(LoopRunTranscriptCodec.transcriptEntry(for: run))
        syncLoopTranscriptMessagingEntries(for: run)
        return run
    }

    @discardableResult
    func resolveHumanApprovalLoopRun(_ runID: UUID, sessionID: UUID, approved: Bool) -> LoopRun? {
        guard var runs = loopRunsBySessionID[sessionID], let index = runs.firstIndex(where: { $0.id == runID }) else { return nil }
        var run = runs[index]
        guard run.structure == .humanApproval, run.status == .stopped, run.stopReason == .humanInputRequired else { return run }
        let now = Date()
        let resolutionIteration = run.currentIteration + 1
        run.status = approved ? .completed : .failed
        run.endedAt = now
        run.stopReason = approved ? .success : .humanRejected
        run.currentIteration = resolutionIteration
        run.iterations.append(LoopIteration(
            index: resolutionIteration,
            startedAt: now,
            endedAt: now,
            summary: approved ? "Human approved checkpoint." : "Human rejected checkpoint.",
            timeline: [LoopTimelineEvent(step: .humanApprovalCheckpoint, roleName: "Human Approval", note: approved ? "Approved" : "Rejected", timestamp: now)]
        ))
        runs[index] = run
        loopRunsBySessionID[sessionID] = runs
        writeLoopProgressFile(for: run)
        upsert(LoopRunTranscriptCodec.transcriptEntry(for: run))
        syncLoopTranscriptMessagingEntries(for: run)
        return run
    }

    func markLoopWorktreeState(runID: UUID, sessionID: UUID, state: LoopWorktreeState) {
        guard var runs = loopRunsBySessionID[sessionID], let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].worktreeState = state
        loopRunsBySessionID[sessionID] = runs
        writeLoopProgressFile(for: runs[index])
        upsert(LoopRunTranscriptCodec.transcriptEntry(for: runs[index]))
    }

    func hydrateLoopRunsFromTranscript(sessionID: UUID) {
        let decodedRuns = (transcriptsBySessionID[sessionID] ?? []).compactMap(LoopRunTranscriptCodec.decode(from:))
        let shouldRecoverInterruptedRuns = loopRecoverySessionIDs.remove(sessionID) != nil
        let now = Date()
        let runs = decodedRuns.map { run -> LoopRun in
            guard shouldRecoverInterruptedRuns, run.isActive else { return run }
            var interrupted = run
            interrupted.status = .interrupted
            interrupted.endedAt = now
            interrupted.stopReason = .appInterrupted
            return interrupted
        }
        if runs.isEmpty {
            loopRunsBySessionID.removeValue(forKey: sessionID)
        } else {
            loopRunsBySessionID[sessionID] = runs
            for run in runs where decodedRuns.first(where: { $0.id == run.id })?.isActive == true {
                upsert(LoopRunTranscriptCodec.transcriptEntry(for: run))
            }
        }
    }

    private func upsertLoopRun(_ run: LoopRun) {
        var runs = loopRunsBySessionID[run.sessionID] ?? []
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        loopRunsBySessionID[run.sessionID] = runs
        writeLoopProgressFile(for: run)
        upsert(LoopRunTranscriptCodec.transcriptEntry(for: run))
        syncLoopTranscriptMessagingEntries(for: run)
    }

    private func syncLoopTranscriptMessagingEntries(for run: LoopRun) {
        loadTranscriptIfNeeded(run.sessionID)
        let entries = transcriptsBySessionID[run.sessionID] ?? []
        let existingRecaps: [(id: UUID, marker: LoopRunRecapMarker)] = entries.compactMap { entry in
            guard let marker = LoopRunRecapCodec.decode(from: entry), marker.runID == run.id else { return nil }
            return (entry.id, marker)
        }
        let existingSeparators: [(id: UUID, marker: LoopRunRecapMarker)] = entries.compactMap { entry in
            guard let marker = LoopIterationSeparatorCodec.decode(from: entry), marker.runID == run.id else { return nil }
            return (entry.id, marker)
        }
        func existingSeparatorID(for marker: LoopRunRecapMarker) -> UUID? {
            existingSeparators.first { $0.marker == marker }?.id
        }
        func existingRecapID(for marker: LoopRunRecapMarker) -> UUID? {
            existingRecaps.first { $0.marker == marker }?.id
        }

        if run.currentIteration > 0 {
            for iterationIndex in 1...run.currentIteration {
                let marker = LoopRunRecapCodec.marker(for: run, iterationIndex: iterationIndex)
                let timestamp = run.iterations.first(where: { $0.index == iterationIndex })?.startedAt ?? Date()
                let entry = LoopIterationSeparatorCodec.transcriptEntry(
                    for: run,
                    iterationIndex: iterationIndex,
                    id: existingSeparatorID(for: marker) ?? UUID(),
                    timestamp: timestamp
                )
                upsert(entry, persist: false)
            }
        }
        for iteration in run.iterations where iteration.index > 0 && iteration.endedAt != nil {
            let marker = LoopRunRecapCodec.marker(for: run, iterationIndex: iteration.index)
            let entry = LoopRunRecapCodec.transcriptEntry(
                for: run,
                iteration: iteration,
                id: existingRecapID(for: marker) ?? UUID()
            )
            upsert(entry, persist: false)
        }
        if !run.isActive {
            let marker = LoopRunRecapCodec.finalMarker(for: run)
            let entry = LoopRunRecapCodec.finalTranscriptEntry(
                for: run,
                id: existingRecapID(for: marker) ?? UUID(),
                progressMarkdown: loopProgressMarkdownForRecap(run)
            )
            upsert(entry, persist: false)
        }
        persistTranscript(run.sessionID)
        evictTranscriptsIfNeeded()
        save()
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

    /// In-place re-run rewind: drop `fromEntryID` and everything after it from
    /// the session's transcript, and rebind the record to the branched Pi
    /// session file the running pi process has already switched to. The session
    /// row, title, worktree, and client all stay — only the conversation tail
    /// disappears (it survives on disk in the parent session file).
    func rewindSession(_ sessionID: UUID, fromEntryID: UUID, newPiSessionFile: String, newPiSessionId: String?) {
        loadTranscriptIfNeeded(sessionID)
        guard transcriptsBySessionID[sessionID] != nil else { return }
        modifyTranscriptEntries(for: sessionID) { entries in
            guard let index = entries.firstIndex(where: { $0.id == fromEntryID }) else { return }
            entries.removeSubrange(index...)
        }
        updateSession(sessionID) { record in
            record.piSessionFile = newPiSessionFile
            record.piSessionId = newPiSessionId
        }
        persistTranscript(sessionID)
        bumpTranscriptRevision(sessionID)
        touchSession(sessionID, bumpUpdatedAt: true)
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
        bumpGitActivityRevisionIfNeeded(for: entry)
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
        bumpGitActivityRevisionIfNeeded(for: entry)
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

    func deleteSessions(_ sessionIDs: Set<UUID>, fallbackSelectionID: UUID? = nil) {
        let existingIDs = Set(sessions.map(\.id)).intersection(sessionIDs)
        guard !existingIDs.isEmpty else { return }

        sessions.removeAll { existingIDs.contains($0.id) }
        bumpSessionListRevision()
        for sessionID in existingIDs {
            cancelTranscriptLoadTask(for: sessionID)
            transcriptsBySessionID[sessionID] = nil
            persistedTranscriptSessionIDs.remove(sessionID)
            pendingPersistTranscriptSnapshots[sessionID] = nil
            loadedTranscriptSessionOrder.removeAll { $0 == sessionID }
            deleteTranscriptFile(sessionID)
            transcriptRevisionsBySessionID[sessionID] = nil
            let runIDs = subagentRunsBySessionID[sessionID]?.map(\.id) ?? []
            for runID in runIDs {
                cancelSubagentTranscriptLoadTask(for: runID)
                subagentTranscriptsByRunID[runID] = nil
                persistedSubagentTranscriptRunIDs.remove(runID)
                pendingPersistSubagentTranscriptSnapshots[runID] = nil
                loadedSubagentTranscriptOrder.removeAll { $0 == runID }
                deleteSubagentTranscriptFile(runID)
            }
            subagentRunsBySessionID[sessionID] = nil
            supervisorRequestsBySessionID[sessionID] = nil
            sessionPlansBySessionID[sessionID] = nil
            sessionPlanEventsBySessionID[sessionID] = nil
            processingActivityBySessionID[sessionID] = nil
            deleteGeneralChatScratchFolders(for: sessionID)
            sessionsTouchedThisRun.remove(sessionID)
        }
        if let currentSelectedSessionID = selectedSessionID, existingIDs.contains(currentSelectedSessionID) {
            // Prefer the caller-supplied neighbor (the row below the deleted set
            // in the user's visible grouped list) so selection follows the user's
            // eyes instead of clamping to the globally most-recent session.
            if let fallbackSelectionID, sessions.contains(where: { $0.id == fallbackSelectionID }) {
                selectedSessionID = fallbackSelectionID
            } else {
                selectedSessionID = sessions.first?.id
            }
        }
        saveStructuralChange()
    }

    func processingActivity(for sessionID: UUID) -> PiAgentProcessingActivity? {
        processingActivityBySessionID[sessionID]
    }

    /// Records what Pi is doing now. Skips the write when unchanged so repeated
    /// streaming deltas don't republish and re-render the transcript.
    func setProcessingActivity(_ activity: PiAgentProcessingActivity?, for sessionID: UUID) {
        if processingActivityBySessionID[sessionID] == activity { return }
        if let activity {
            processingActivityBySessionID[sessionID] = activity
        } else {
            processingActivityBySessionID.removeValue(forKey: sessionID)
        }
    }

    func clearTranscript(for sessionID: UUID) {
        cancelTranscriptLoadTask(for: sessionID)
        transcriptsBySessionID[sessionID] = []
        persistTranscript(sessionID)
        markTranscriptSessionUsed(sessionID)
        bumpTranscriptRevision(sessionID)
        save()
    }

    private func applyLoadedPersistedState(_ loaded: LoadedPersistedState) {
        switch loaded {
        case .missing:
            return
        case .error(let message):
            lastError = "Could not load Pi Agent sessions: \(message)"
            sessions = []
            bumpSessionListRevision()
            transcriptsBySessionID = [:]
            selectedSessionID = nil
            return
        case .lazy(let persisted, let manifest):
            applyPersistedIndex(persisted, manifest: manifest)
            return
        case .full(let persisted):
            applyFullPersistedState(persisted)
        }
    }

    private func applyFullPersistedState(_ persisted: PersistedState) {
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
                        request.response = request.response ?? "Cancelled because the child Deck agent is no longer connected."
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
            loopRecoverySessionIDs = persistedTranscriptSessionIDs
            persistedSubagentTranscriptRunIDs = Set(subagentTranscriptsByRunID.keys)
            writeLoadedTranscriptFilesAndManifest()
            if lazyTranscriptLoadingEnabled {
                evictTranscriptsIfNeeded()
                if let id = selectedSessionID { requestTranscriptLoad(for: id) }
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
        loopRecoverySessionIDs = persistedTranscriptSessionIDs
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
                    request.response = request.response ?? "Cancelled because the child Deck agent is no longer connected."
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
        // Kick the selected session's transcript load synchronously so
        // `isSelectedTranscriptLoading` is already true by the time the view
        // first renders — otherwise the transcript area is briefly blank.
        if let id = selectedSessionID { requestTranscriptLoad(for: id) }
    }

    /// Bump the coarse git-activity signal iff this entry is one the activity
    /// badges read (a `.status` row whose title is a commit/push/merge event).
    /// Mirrors the predicate in `piAgentSessionGitActivity` so the two never drift.
    private func bumpGitActivityRevisionIfNeeded(for entry: PiAgentTranscriptEntry) {
        guard entry.role == .status, PiAgentGitEventKind.from(title: entry.title) != nil else { return }
        gitActivityRevision &+= 1
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
        bumpSessionListRevision()
    }

    private func bumpSessionListRevision() {
        sessionListRevision &+= 1
        refreshDockAttentionBadge()
    }

    /// Dock badge mirrors the per-row bells: how many sessions finished and
    /// are waiting for review. Driven from the revision bump rather than a
    /// view so it stays correct while the app is in the background, which is
    /// exactly when sessions go needs-attention.
    private func refreshDockAttentionBadge() {
        let count = sessions.count(where: \.needsAttention)
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }

    private func touchSession(_ id: UUID, bumpUpdatedAt: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            save()
            return
        }
        if bumpUpdatedAt {
            // Same rationale as updateSession: sessionListPrecedes compares updatedAt at
            // day granularity, so a same-day touch never reorders. Streaming sessions hit
            // this path many times per second via store.append → save the sort write.
            let now = Date()
            let calendar = Calendar.current
            let preDay = calendar.startOfDay(for: sessions[index].updatedAt)
            let newDay = calendar.startOfDay(for: now)
            sessions[index].updatedAt = now
            // Record the touch as part of the current app run, even when the
            // store's sort order doesn't change. The expanded sidebar uses this
            // set to surface recently-jostled sessions above its top-N cap.
            sessionsTouchedThisRun.insert(id)
            if preDay != newDay {
                sortSessions()
            }
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
        hydrateLoopRunsFromTranscript(sessionID: sessionID)
    }

    private func finishRequestedTranscriptLoad(_ sessionID: UUID, entries: [PiAgentTranscriptEntry]) {
        guard transcriptLoadTasksBySessionID[sessionID] != nil else { return }
        transcriptLoadTasksBySessionID[sessionID] = nil
        transcriptLoadingSessionIDs.remove(sessionID)
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        if transcriptsBySessionID[sessionID] == nil {
            transcriptsBySessionID[sessionID] = entries
            hydrateLoopRunsFromTranscript(sessionID: sessionID)
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
        persistedTranscriptSessionIDs.insert(sessionID)
        // Snapshot entries at call time so later eviction of the in-memory transcript
        // can't drop our write. Repeated calls overwrite the snapshot with the latest
        // entries; the flush always writes the freshest snapshot per session.
        pendingPersistTranscriptSnapshots[sessionID] = transcriptsBySessionID[sessionID] ?? []
        schedulePendingPersistTranscriptFlush()
    }

    private func persistSubagentTranscript(_ runID: UUID) {
        persistedSubagentTranscriptRunIDs.insert(runID)
        pendingPersistSubagentTranscriptSnapshots[runID] = subagentTranscriptsByRunID[runID] ?? []
        schedulePendingPersistTranscriptFlush()
    }

    private func schedulePendingPersistTranscriptFlush() {
        guard pendingPersistTranscriptTask == nil else { return }
        pendingPersistTranscriptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.transcriptPersistDebounceNanoseconds ?? 750_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.flushPendingPersistTranscripts(synchronous: false)
            }
        }
    }

    private func flushPendingPersistTranscripts(synchronous: Bool) {
        pendingPersistTranscriptTask?.cancel()
        pendingPersistTranscriptTask = nil
        let parentSnapshots = pendingPersistTranscriptSnapshots
        let subagentSnapshots = pendingPersistSubagentTranscriptSnapshots
        pendingPersistTranscriptSnapshots.removeAll()
        pendingPersistSubagentTranscriptSnapshots.removeAll()
        if parentSnapshots.isEmpty && subagentSnapshots.isEmpty { return }

        let parents = parentSnapshots.map { (id, entries) in
            (parentTranscriptURL(id), PersistedTranscript(sessionID: id, entries: entries))
        }
        let subagents = subagentSnapshots.map { (id, entries) in
            (subagentTranscriptURL(id), PersistedSubagentTranscript(runID: id, entries: entries))
        }

        let work: @Sendable () -> Void = {
            for (url, payload) in parents {
                try? Self.writeParentTranscript(payload, to: url)
            }
            for (url, payload) in subagents {
                try? Self.writeSubagentTranscript(payload, to: url)
            }
        }

        if synchronous {
            saveQueue.sync(execute: work)
        } else {
            saveQueue.async(execute: work)
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

    private func transcriptFileIsSmallEnoughForSyncDecode(_ fileURL: URL) -> Bool {
        guard let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return false
        }
        return size <= Self.maxSyncDecodeTranscriptBytes
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

    private func deleteGeneralChatScratchFolders(for sessionID: UUID) {
        let urls = [
            PiAgentSessionRecord.generalChatScratchRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true),
            PiAgentSessionRecord.legacyNoProjectScratchRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        ]
        saveQueue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
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

    private func makePersistedStateIndexSnapshot() -> (sequence: Int, state: PersistedStateIndex) {
        saveSequence &+= 1
        let persisted = PersistedStateIndex(
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            subagentRuns: subagentRunsBySessionID.map { PersistedSubagentRuns(sessionID: $0.key, runs: $0.value) },
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
        let usesStateIndex = lazyTranscriptLoadingEnabled
        let sequence: Int
        let persistedState: PersistedState?
        let persistedIndex: PersistedStateIndex?
        if usesStateIndex {
            let snapshot = makePersistedStateIndexSnapshot()
            sequence = snapshot.sequence
            persistedState = nil
            persistedIndex = snapshot.state
        } else {
            let snapshot = makePersistedStateSnapshot()
            sequence = snapshot.sequence
            persistedState = snapshot.state
            persistedIndex = nil
        }
        saveQueue.async { [weak self, fileURL, transcriptManifestURL, manifest, persistedState, persistedIndex, sequence] in
            do {
                try Self.writeTranscriptManifest(manifest, to: transcriptManifestURL)
                if let persistedIndex {
                    try Self.write(persistedIndex, to: fileURL)
                } else if let persistedState {
                    try Self.write(persistedState, to: fileURL)
                }
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
        let persistedState: PersistedState?
        let persistedIndex: PersistedStateIndex?
        if lazyTranscriptLoadingEnabled {
            persistedState = nil
            persistedIndex = makePersistedStateIndexSnapshot().state
        } else {
            persistedState = makePersistedStateSnapshot().state
            persistedIndex = nil
        }
        do {
            try saveQueue.sync {
                try Self.writeTranscriptManifest(manifest, to: transcriptManifestURL)
                if let persistedIndex {
                    try Self.write(persistedIndex, to: fileURL)
                } else if let persistedState {
                    try Self.write(persistedState, to: fileURL)
                }
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

    private nonisolated static func write(_ persisted: PersistedStateIndex, to fileURL: URL) throws {
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

private nonisolated struct PersistedState: Codable, Sendable {
    var sessions: [PiAgentSessionRecord]
    var transcripts: [PersistedTranscript]
    var selectedSessionID: UUID?
    var subagentRuns: [PersistedSubagentRuns]?
    var subagentTranscripts: [PersistedSubagentTranscript]?
    var supervisorRequests: [PersistedSupervisorRequests]?
    var sessionPlans: [PiSessionPlanRecord]?
    var sessionPlanEvents: [PiSessionPlanEventRecord]?
}

private nonisolated struct PersistedStateIndex: Codable, Sendable {
    var sessions: [PiAgentSessionRecord]
    var selectedSessionID: UUID?
    var subagentRuns: [PersistedSubagentRuns]?
    var supervisorRequests: [PersistedSupervisorRequests]?
    var sessionPlans: [PiSessionPlanRecord]?
    var sessionPlanEvents: [PiSessionPlanEventRecord]?
}

private nonisolated struct PersistedTranscript: Codable, Sendable {
    var sessionID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private nonisolated struct PersistedSubagentRuns: Codable, Sendable {
    var sessionID: UUID
    var runs: [PiSubagentRunRecord]
}

private nonisolated struct PersistedSubagentTranscript: Codable, Sendable {
    var runID: UUID
    var entries: [PiAgentTranscriptEntry]
}

private nonisolated struct PersistedSupervisorRequests: Codable, Sendable {
    var sessionID: UUID
    var requests: [PiSubagentSupervisorRequest]
}

private nonisolated struct TranscriptManifest: Codable, Sendable {
    var parentSessionIDs: [UUID]
    var subagentRunIDs: [UUID]
}

private enum LoadedPersistedState: Sendable {
    case lazy(PersistedStateIndex, TranscriptManifest)
    case full(PersistedState)
    case missing
    case error(String)
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
