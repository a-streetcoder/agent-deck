import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentScreen: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @ObservedObject private var languageStore = LanguageStore.shared
    @Binding var sessionSearchText: String
    var showsSessionsColumn = true
    /// False when this screen is kept mounted but hidden (the user is on another
    /// sidebar tab). While inactive the transcript stops rebuilding its rows on
    /// streaming pulses — see `appKitTranscriptItems`.
    var isActive = true
    @State private var composerText = ""
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    /// Cached slash universe. Built once when the `/` panel opens (off the body
    /// hot path, in `.onChange`) and reused for the whole interaction so neither
    /// typing nor scrolling re-walks the catalog.
    @State private var slashUniverse: SlashUniverse = .empty
    @State private var slashState = SlashSuggestionState()
    @State private var slashUniverseRevision = 0
    @State private var slashRowsCacheKey: SlashSuggestionRowsCacheKey?
    @State private var cachedSlashRows: [SlashSuggestionRow] = []
    @State private var cachedSlashSelectableRows: [SlashSuggestionRow] = []
    /// Picked slash items — rendered as glass capsule chips above the editor and
    /// included in the send payload. Only skills/skill collections can stack.
    @State private var slashSelections: [SlashItem] = []
    @State private var isLoopLaunchSheetPresented = false
    @State private var loopLaunchDraft = LoopDraft()
    @State private var loopLaunchDefinition: LoopDefinition?
    @State private var lastSlashTriggerActive = false
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var pendingDeleteIsClearAll = false
    @State private var pendingDeleteClearAllProjects = false
    @State private var pendingDeleteProjectName: String?
    @State private var isDeleteSessionsAlertPresented = false
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var composerHistoryIndex: Int?
    @State private var composerHistoryDraft = ""
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    // Owned but NOT observed: `@State` (not `@StateObject`) holds the cache for the
    // view's lifetime without subscribing `PiAgentScreen.body` to its
    // `objectWillChange`. The cache pulses `streamingRevision` ~30Hz while a session
    // streams; subscribing the whole screen re-evaluated the session list + composer
    // on every pulse (the SessionListContent re-eval storm). Only the extracted
    // `PiAgentTranscriptHost` child takes the cache as `@ObservedObject`, so the
    // pulse now re-renders the transcript table alone. The cache is driven entirely
    // by `store.*`-keyed `.task`/`.onChange` triggers, which the parent still
    // observes — so dropping the subscription doesn't miss any update.
    @State private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var transcriptBottomScrollRequest = 0
    // Pinned-to-bottom lives in its own ObservableObject, held by `@State` so this
    // screen's body watches only the reference identity — NOT `isPinned`. Scrolling
    // flips `isPinned` ~constantly; if the screen body read it directly, every flip
    // would re-evaluate the whole body and re-run the O(N) `appKitTranscriptItems`
    // build (the `itemsBuild` scroll cost). Only `JumpToLatestOverlay` `@ObservedObject`s
    // it, so a flip re-renders just the pill, leaving the transcript host untouched.
    @State private var transcriptPinnedState = TranscriptPinnedState()
    @State private var showArchivedPreCompactionTranscript = false
    @State private var isEarlierTranscriptSheetPresented = false
    @State private var cachedSections: [PiAgentSessionListSection] = []
    @State private var hasBuiltVisibleSessions = false
    @State private var sessionScrollRequest: UUID?
    /// Per-session derived git activity (commit/push/merge timestamps), keyed by
    /// session.id. Rebuilt off the body hot path on transcript-revision or
    /// visible-set changes — never recomputed inline in row `body` to avoid
    /// jank (see `[[feedback_performance_sensitive]]`).
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State private var isUIRequestSheetPresented = false
    @State private var isSupervisorRequestSheetPresented = false
#if DEBUG
    @State private var didStartPickerStress = false
    @State private var pickerStressExpansionRequest = false
    @State private var pickerStressRowSource: PickerStressRowSource = .synthetic
    @State private var pickerStressAcknowledgements = PickerStressCardAcknowledgements()
#endif
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State private var stabilizedProcessingMessage: String?
    @State private var processingMessageUpdateTask: Task<Void, Never>?
    // True while a Review/sidebar splitter drag is active. Suppresses the
    // transcript edge-fade `.mask` (which smears into a blur mask over the
    // middle column mid-drag) until the drag ends and the table re-lays out.
    @State private var isColumnResizing = false

    // Keep long sessions cheap to relayout when side panels open; older visible items remain accessible separately.
    private let recentTranscriptTimelineItemLimit = 50

    var body: some View {
        HStack(spacing: 0) {
            if showsSessionsColumn {
                HSplitView {
                    sessionsColumn
                        .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

                    activeSessionPaneBoundary
                }
            } else {
                activeSessionPaneBoundary
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            syncRuntimeFooterSnapshot()
            isUIRequestSheetPresented = store.selectedUIRequest != nil
            isSupervisorRequestSheetPresented = selectedPendingSupervisorRequest != nil && store.selectedUIRequest == nil
            rebuildVisibleSessions()
            resetTranscriptAutoScroll()
            // Transcript loading mutates the observable store's loading set. It
            // must happen after this appearance pass, not while SwiftUI is
            // publishing the selected-session update.
            requestSelectedTranscriptLoadAfterViewUpdate(for: store.selectedSession?.id)
            updateStabilizedProcessingMessage(selectedSessionProcessingMessage)
            Task { @MainActor in
                await Task.yield()
#if DEBUG
                await runPickerStressIfRequested()
#endif
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.expandedProjects) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.collapsedProjects) { _, _ in rebuildVisibleSessions() }
        // Projects load asynchronously after sessions on first launch; without
        // this trigger the cached sections stayed grouped under "Other" until a
        // later rebuild.
        .onChange(of: viewModel.discoveredProjectsRevision) { _, _ in rebuildVisibleSessions() }
        .onDisappear {
            processingMessageUpdateTask?.cancel()
            processingMessageUpdateTask = nil
        }
        // Suppress the transcript edge-fade blur mask while a splitter drag is
        // active; re-enable once the drag ends and the column re-settles.
        .onReceive(NotificationCenter.default.publisher(for: .transcriptColumnResizeActive)) { note in
            let active = (note.userInfo?["active"] as? Bool) ?? false
            if isColumnResizing != active {
                isColumnResizing = active
            }
        }
        .sheet(isPresented: uiRequestSheetBinding) {
            if let request = store.selectedUIRequest {
                PiAgentUIRequestSheet(
                    request: request,
                    onSubmitValue: { value in viewModel.respondToPiAgentUIRequest(request, value: value) },
                    onSubmitFreeform: { sentinel, value in viewModel.respondToPiAgentFreeformUIRequest(request, sentinel: sentinel, value: value) },
                    onConfirm: { confirmed in viewModel.confirmPiAgentUIRequest(request, confirmed: confirmed) },
                    onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                )
            }
        }
        .sheet(isPresented: supervisorRequestSheetBinding) {
            if let request = selectedPendingSupervisorRequest {
                PiSubagentSupervisorRequestSheet(
                    request: request,
                    onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID, response: response) },
                    onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
                )
            }
        }
        .sheet(isPresented: $isLoopLaunchSheetPresented) {
            if let session = store.selectedSession,
               let projectPath = session.projectPathForProjectFeatures {
                LoopLaunchSheet(
                    session: session,
                    activeRun: store.activeLoopRun(for: session.id),
                    initialDraft: loopLaunchDraft,
                    sourceDefinition: loopLaunchDefinition,
                    availableAgents: viewModel.allDisplayAgents,
                    projectAgents: viewModel.startupSnapshot(forProjectPath: projectPath).effectiveAgents,
                    onCancel: { isLoopLaunchSheetPresented = false },
                    onAssignMissingAgents: { names in
                        viewModel.assignAgentNames(names, toProjectPath: projectPath)
                    },
                    onEnableDeckAgents: {
                        viewModel.setSubagentsEnabled(true, forSessionID: session.id)
                    },
                    onLaunch: { request in
                        if store.activeLoopRun(for: session.id) != nil && !request.stopExistingActive {
                            store.append(.init(sessionID: session.id, role: .error, title: LanguageStore.shared.t("agent.loopLaunchFailed"), text: "This transcript already has an active loop."))
                            return
                        }
                        if let saveRequest = request.saveRequest {
                            do {
                                try viewModel.saveLoopDefinitionFromDraft(request.draft, request: saveRequest)
                            } catch {
                                store.append(.init(sessionID: session.id, role: .error, title: LanguageStore.shared.t("agent.loopSaveFailed"), text: error.localizedDescription))
                                return
                            }
                        }
                        Task { @MainActor in
                            isLoopLaunchSheetPresented = false
                            let launched = await viewModel.launchLoop(
                                session: session,
                                draft: request.draft,
                                stopExistingActive: request.stopExistingActive
                            )
                            guard launched != nil else {
                                store.append(.init(sessionID: session.id, role: .error, title: LanguageStore.shared.t("agent.loopLaunchFailed"), text: "The loop could not be started."))
                                return
                            }
                        }
                    }
                )
            }
        }
        .onChange(of: store.selectedUIRequest?.id) { _, newID in
            isUIRequestSheetPresented = newID != nil
            if newID == nil, selectedPendingSupervisorRequest != nil {
                isSupervisorRequestSheetPresented = true
            }
        }
        .onChange(of: selectedPendingSupervisorRequest?.id) { _, newID in
            isSupervisorRequestSheetPresented = newID != nil && store.selectedUIRequest == nil
        }
        .onChange(of: store.selectedSession?.id) { oldID, newID in
            if let newID, !selectedSessionIDs.contains(newID) {
                syncMultiSelectionToSelectedSession()
            } else if newID == nil {
                selectedSessionIDs = []
                lastSelectedSessionID = nil
            }
            resetTranscriptAutoScroll()
            showArchivedPreCompactionTranscript = false
            isEarlierTranscriptSheetPresented = false
            syncRuntimeFooterSnapshot()
            resetSlashComposerState()
            // Loading and cache hydration publish observable state. Schedule the
            // selected identity after this update pass so session selection never
            // triggers "Publishing changes from within view updates". The helper
            // verifies the identity again after yielding, coalescing rapid clicks.
            requestSelectedTranscriptLoadAfterViewUpdate(for: newID)
            Task { @MainActor in
                await Task.yield()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
            rebuildSessionActivityCache()
        }
        .onChange(of: store.transcriptRevisionsBySessionID) { _, _ in
            rebuildSessionActivityCache()
        }
        .task(id: store.selectedTranscriptRevision) {
            await handleSelectedTranscriptRevisionTask()
        }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(
                run: run,
                store: store,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility
            )
            .onAppear {
                requestSubagentTranscriptLoadAfterViewUpdate(runID: run.id)
            }
        }
        .sheet(isPresented: $isEarlierTranscriptSheetPresented) {
            earlierTranscriptSheet
        }
        .sheet(item: selectedSubagentGraphBinding) { run in
            PiNativeSubagentGraphSheet(
                run: run,
                onStopGraph: { viewModel.stopNativeSubagentGraph(runID: run.id, parentSessionID: run.parentSessionID) },
                onStopChild: { child in viewModel.stopNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onRetryChild: { child in viewModel.retryNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onOpenChildArtifacts: { child in if let path = child.artifactDirectory { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            )
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button(
                pendingDeleteIsClearAll
                    ? LanguageStore.shared.t("common.clear")
                    : LanguageStore.shared.t("common.delete"),
                role: .destructive,
                action: deletePendingSessions
            )
            Button(LanguageStore.shared.t("common.cancel"), role: .cancel) {
                resetPendingSessionDelete()
            }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private func handleSelectedTranscriptRevisionTask() async {
        await Task.yield()
        scheduleTranscriptCacheUpdate()
    }

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        store.sessions
    }

    private var isAllProjects: Bool { true }

    private var visibleSections: [PiAgentSessionListSection] {
        hasBuiltVisibleSessions ? cachedSections : computedSections()
    }

    /// Flattened rendered sessions (preview sets only) for helpers that still
    /// think in terms of a flat list — selection sync, working set, activity
    /// cache. Hidden sessions are intentionally excluded.
    private var visibleSessions: [PiAgentSessionRecord] { visibleSections.flatMap(\.items) }

    private func rebuildVisibleSessions() {
        let next = computedSections()
        // Only write @State when the visible list actually changed. A bare
        // `sessionListRevision` bump (e.g. a background re-sort/refresh while the
        // user is just scrolling the transcript) otherwise re-evaluates the whole
        // screen body and re-runs the transcript's updateNSView for nothing.
        if !hasBuiltVisibleSessions || next != cachedSections {
            cachedSections = next
        }
        hasBuiltVisibleSessions = true
    }

    private func computedSections() -> [PiAgentSessionListSection] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        let filtered = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
        // Cap previews only in All-Projects browsing — searching or filtering by
        // attention bypasses the cap (the user is hunting), and a scoped project
        // keeps its full flat list exactly as before.
        let capPreviews = isAllProjects && query.isEmpty && !viewModel.showPiAgentAttentionOnly
        return PiAgentSessionGrouping.sections(
            from: filtered,
            projectByPath: viewModel.projectByPath,
            projectDiscoveryComplete: viewModel.hasCompletedInitialProjectDiscovery,
            expandedProjectIDs: viewModel.expandedProjects,
            collapsedProjectIDs: viewModel.collapsedProjects,
            capPreviews: capPreviews,
            isWorking: { viewModel.piAgentSessionIsWorking($0) },
            selectedSessionID: store.selectedSession?.id
        )
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private func rebuildSessionActivityCache() {
        var fresh: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions {
            let entries = store.transcriptsBySessionID[session.id] ?? []
            let activity = piAgentSessionGitActivity(from: entries)
            if activity.hasCommit || activity.hasPush || activity.hasMerge {
                fresh[session.id] = activity
            }
        }
        if fresh != sessionActivityCache {
            sessionActivityCache = fresh
        }
    }

    private var deleteSessionsAlertTitle: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects { return LanguageStore.shared.t("session.clearAllTitle") }
            let projectName = pendingDeleteProjectName ?? LanguageStore.shared.t("session.thisProject")
            return LanguageStore.shared.t("session.clearProjectTitle", projectName)
        }
        return pendingDeleteSessionIDs.count == 1
            ? LanguageStore.shared.t("session.deleteTitle")
            : LanguageStore.shared.t("session.deleteTitleMany", pendingDeleteSessionIDs.count)
    }

    private var deleteSessionsAlertMessage: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects {
                return LanguageStore.shared.t("session.clearAllMessage")
            }
            let projectName = pendingDeleteProjectName ?? LanguageStore.shared.t("session.currentProject")
            return LanguageStore.shared.t("session.clearProjectMessage", projectName)
        }
        return pendingDeleteSessionIDs.count == 1
            ? LanguageStore.shared.t("session.deleteMessage")
            : LanguageStore.shared.t("session.deleteMessageMany")
    }

    private var sessionDeleteTargets: Set<UUID> {
        if !selectedSessionIDs.isEmpty {
            return selectedSessionIDs
        }
        if let selectedID = store.selectedSession?.id {
            return [selectedID]
        }
        return []
    }

    private var uiRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isUIRequestSheetPresented && store.selectedUIRequest != nil },
            set: { isPresented in
                if isPresented {
                    isUIRequestSheetPresented = true
                } else {
                    isUIRequestSheetPresented = false
                }
            }
        )
    }

    private var supervisorRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isSupervisorRequestSheetPresented && selectedPendingSupervisorRequest != nil && store.selectedUIRequest == nil },
            set: { isPresented in
                if isPresented {
                    isSupervisorRequestSheetPresented = true
                } else {
                    isSupervisorRequestSheetPresented = false
                }
            }
        )
    }

    private var selectedPendingSupervisorRequest: PiSubagentSupervisorRequest? {
        guard let sessionID = store.selectedSession?.id else { return nil }
        return store.supervisorRequests(for: sessionID)
            .filter { $0.status == .pending && $0.kind.isBlocking }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
            .first
    }


    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text(LanguageStore.shared.t("session.title"))
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if selectedSessionIDs.count > 1 {
                        Button(role: .destructive) {
                            requestDeleteSessions(selectedSessionIDs)
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(AppTheme.Font.body.weight(.semibold))
                                .foregroundStyle(Color.red)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(LanguageStore.shared.t("session.deleteSelected"))
                        .accessibilityLabel(LanguageStore.shared.t("session.deleteSelected"))
                    }
                    if viewModel.appSettings.nativeSubagentsEnabledForNewSessions {
                        PiAgentNewSessionSplitButton(
                            viewModel: viewModel,
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            onNewSession: { viewModel.createPiAgentDraftForSelectedProject() },
                            onNewSessionForProject: { viewModel.createPiAgentDraft(for: $0) }
                        )
                    } else if viewModel.selectedDiscoveredProject == nil {
                        PiAgentAddSessionMenuButton(
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            action: { viewModel.createNoProjectPiAgentDraft() },
                            onSelectAgentDeckBuilder: { viewModel.createAgentDeckBuilderDraft() },
                            onSelectProject: { project in
                                viewModel.createPiAgentDraft(for: project)
                            }
                        )
                    } else {
                        PiAgentAddSessionButton(
                            action: { viewModel.createPiAgentDraftForSelectedProject() }
                        )
                    }
                }

                PiAgentSessionSearchField(text: $sessionSearchText)
            }
            .padding(.vertical, 18)
            // 14 keeps the title flush with the session rows' text (6 AppList
            // inset + 8 row padding).
            .padding(.horizontal, 14)

            if scopedSessions.isEmpty {
                AppEmptyState(
                    LanguageStore.shared.t("session.empty"),
                    systemImage: "square.and.pencil",
                    description: emptySessionsMessage,
                    layout: .fill
                )
            } else {
                VStack(spacing: 10) {
                    if visibleSessions.isEmpty {
                        AppEmptyState(
                            LanguageStore.shared.t("session.noneFound"),
                            systemImage: "magnifyingglass",
                            description: LanguageStore.shared.t("session.trySearch"),
                            layout: .fill
                        )
                    } else {
                        SessionListContent(
                            sections: visibleSections,
                            isGrouped: isAllProjects,
                            selectedSessionIDs: selectedSessionIDs,
                            workingSessionIDs: workingVisibleSessionIDs,
                            uiRequestSessionIDs: uiRequestVisibleSessionIDs,
                            generatingTitleIDs: viewModel.piAgentTitleGeneratingSessionIDs,
                            activeLoopSessionIDs: activeLoopSessionIDs,
                            activityByID: visibleSessionActivityByID,
                            projectByPath: viewModel.projectByPath,
                            compactSessionIDs: [],
                            scrollRequestID: sessionScrollRequest,
                            scrollRequest: $sessionScrollRequest,
                            selection: $selectedSessionIDs,
                            onSelect: { session in
                                selectSessionFromList(session)
                            },
                            onDelete: { id in
                                requestDeleteSessions(
                                    selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1
                                        ? selectedSessionIDs
                                        : [id]
                                )
                            },
                            onSetPinned: { id, pinned in
                                viewModel.setPiAgentSessionPinned(id, pinned: pinned)
                                Task { @MainActor in
                                    await Task.yield()
                                    sessionScrollRequest = id
                                }
                            },
                            onShowMorePrevious: {},
                            onToggleExpand: { projectID in
                                if viewModel.expandedProjects.contains(projectID) { viewModel.expandedProjects.remove(projectID) }
                                else { viewModel.expandedProjects.insert(projectID) }
                            },
                            onToggleCollapse: { projectID in
                                if viewModel.collapsedProjects.contains(projectID) { viewModel.collapsedProjects.remove(projectID) }
                                else { viewModel.collapsedProjects.insert(projectID) }
                            },
                            onCreateSessionForProject: { projectPath in
                                if projectPath == PiAgentSessionGrouping.noProjectSectionID {
                                    viewModel.createNoProjectPiAgentDraft()
                                } else if projectPath == PiAgentSessionGrouping.agentDeckBuilderSectionID {
                                    viewModel.createAgentDeckBuilderDraft()
                                } else if let project = viewModel.projectByPath[projectPath] {
                                    viewModel.createPiAgentDraft(for: project)
                                }
                            },
                            onArrowNavigate: { direction in
                                viewModel.selectAdjacentPiAgentSession(offset: direction == .down ? 1 : -1, wrap: false)
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
        .background(Color.clear)
    }

    // Per-row dynamic state resolved up front so the session list can be an
    // Equatable view (see SessionListContent): comparing these resolved values is
    // what lets a streaming-cadence body re-eval skip the list unless a row's
    // contents actually changed. Each iterates only the (cached) visible sessions.
    private var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var uiRequestVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

#if DEBUG
    private var isPickerStressRequested: Bool {
        ProcessInfo.processInfo.environment["AGENTDECK_PICKER_STRESS"] != nil
    }

    @MainActor
    private func runPickerStressIfRequested() async {
        guard isPickerStressRequested, !didStartPickerStress else { return }
        didStartPickerStress = true

        viewModel.openPiAgentScreen()
        // Let PiAgentScreen finish its on-appear selection restoration before
        // creating the journey draft; otherwise that restoration can select a
        // persisted session over the freshly created one.
        try? await Task.sleep(for: .milliseconds(500))
        // This journey is invalid without a real project-backed draft. Wait for
        // normal discovery first; only when it is empty, resolve the harness
        // path transiently without publishing a project preference or selection.
        for _ in 0..<20 where viewModel.discoveredProjects.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let project = viewModel.selectedProjectPath.flatMap({ viewModel.projectByPath[$0] })
                ?? viewModel.discoveredProjects.sorted(by: { $0.path < $1.path }).first
                ?? pickerStressProjectFromEnvironment() else {
            pickerStressLog("PICKER_STRESS FAIL no discovered or harness project; cannot create project draft")
            NSApp.terminate(nil)
            return
        }

        let originalSelection = store.selectedSessionID
        let originalNewSessionSubagentsEnabled = store.newSessionSubagentsEnabled
        var harnessSessionID: UUID?
        var didCleanupHarness = false
        func cleanupHarness() {
            guard !didCleanupHarness else { return }
            didCleanupHarness = true
            if let harnessSessionID {
                store.deleteSession(harnessSessionID)
            }
            store.newSessionSubagentsEnabled = originalNewSessionSubagentsEnabled
            if let originalSelection, store.sessions.contains(where: { $0.id == originalSelection }) {
                viewModel.selectPiAgentSession(originalSelection)
            } else {
                viewModel.releaseTransientFocusedPiAgentSession()
                store.clearSelection()
            }
            store.flushPendingSave()
        }
        defer { cleanupHarness() }
        func failStress(_ message: String) {
            pickerStressLog("PICKER_STRESS FAIL \(message)")
            cleanupHarness()
            NSApp.terminate(nil)
        }

        // The isolated stress store owns this draft exclusively. Never reuse a
        // visible/user session, even when its project happens to match.
        let draft = store.createSession(
            kind: .project,
            title: "Picker stress draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        harnessSessionID = draft.id
        viewModel.setSubagentsEnabled(true, forSessionID: draft.id)
        pickerStressRowSource = .synthetic
        pickerStressAcknowledgements.reset(for: draft.id)
        pickerStressLog("PICKER_STRESS PREPARE created isolated draft path=\(project.path) session=\(draft.id.uuidString)")

        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            failStress("no visible app window")
            return
        }

        let sessionID = draft.id.uuidString
        let rounds = 28
        let initialSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let stressScene = "PickerStress"
        let resizeScene = "PickerResizeStress"
        // Only use supported full-window sizes. The app's content/split minima
        // make artificial 620pt requests a clipping test rather than a resize.
        let sizes: [NSSize] = [
            .init(width: 1_346, height: 915),
            .init(width: 900, height: 720),
            .init(width: 1_000, height: 700),
            .init(width: 1_200, height: 800),
            .init(width: 1_600, height: 900),
            .init(width: 1_050, height: 720)
        ]
        pickerStressLog("PICKER_STRESS START session=\(sessionID) rounds=\(rounds) window=\(Int(initialSize.width))x\(Int(initialSize.height))")
        defer {
            PerfScene.current = "app"
            window.setContentSize(initialSize)
        }
        // Let launch-time scanning settle, then demand acknowledgements from
        // the production card before measuring the real resize/toggle cycle.
        try? await Task.sleep(for: .milliseconds(500))
        pickerStressExpansionRequest = true
        guard await waitForPickerStressCard(
            sessionID: draft.id,
            expanded: true,
            rowSource: .synthetic,
            afterCatalogGeometryRevision: 0
        ) else {
            failStress("synthetic production card did not mount and expand for project path=\(project.path)")
            return
        }
        guard pickerStressAcknowledgements.rowCount == 12,
              pickerStressCatalogHeightIsApproximately(532) else {
            failStress("synthetic transition evidence rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize)); expected rows=12 height≈532")
            return
        }
        pickerStressLog("PICKER_STRESS TRANSITION synthetic rows=12 catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize)) revision=\(pickerStressAcknowledgements.catalogGeometryRevision)")

        let syntheticCatalogRevision = pickerStressAcknowledgements.catalogGeometryRevision
        // Keep the same mounted card expanded; only exchange its DEBUG row source.
        pickerStressRowSource = .resolved
        guard await waitForPickerStressCard(
            sessionID: draft.id,
            expanded: true,
            rowSource: .resolved,
            afterCatalogGeometryRevision: syntheticCatalogRevision
        ) else {
            failStress("resolved transition acknowledgement missing after syntheticRevision=\(syntheticCatalogRevision) rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize))")
            return
        }
        guard pickerStressAcknowledgements.rowCount == 4,
              pickerStressCatalogHeightIsApproximately(212) else {
            failStress("resolved transition evidence rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize)); expected rows=4 height≈212")
            return
        }
        pickerStressLog("PICKER_STRESS TRANSITION resolved rows=4 catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize)) revision=\(pickerStressAcknowledgements.catalogGeometryRevision)")

        let initialHangCount = HangWatchdog.hangCount(forScene: stressScene)
        let initialResizeHangCount = HangWatchdog.hangCount(forScene: resizeScene)

        for index in 0..<rounds {
            guard !Task.isCancelled else {
                pickerStressLog("PICKER_STRESS CANCELLED round=\(index)")
                cleanupHarness()
                NSApp.terminate(nil)
                return
            }
            let size = sizes[index % sizes.count]
            PerfScene.current = resizeScene
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(250))
            let actualSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
            guard abs(actualSize.width - size.width) <= 2, abs(actualSize.height - size.height) <= 2 else {
                failStress("window size requested=\(pickerStressSizeDescription(size)) actual=\(pickerStressSizeDescription(actualSize))")
                return
            }
            let expanded = index.isMultiple(of: 2)
            PerfScene.current = stressScene
            pickerStressExpansionRequest = expanded
            try? await Task.sleep(for: .milliseconds(180))
            guard await waitForPickerStressCard(
                sessionID: draft.id,
                expanded: expanded,
                rowSource: .resolved,
                afterCatalogGeometryRevision: 0
            ) else {
                failStress("card expansion acknowledgement missing round=\(index + 1)")
                return
            }
            pickerStressLog("PICKER_STRESS ROUND=\(index + 1)/\(rounds) requested=\(pickerStressSizeDescription(size)) actual=\(pickerStressSizeDescription(actualSize)) expanded=\(expanded) rows=\(pickerStressAcknowledgements.rowCount) catalogViewport=\(pickerStressSizeDescription(pickerStressAcknowledgements.catalogSize))")
        }

        // Include the final layout/animation settle in the measured region,
        // then restore the normal scene before application termination so an
        // unrelated shutdown stall cannot be misattributed to the picker.
        try? await Task.sleep(for: .milliseconds(300))
        let hangs = HangWatchdog.hangCount(forScene: stressScene) - initialHangCount
        let resizeHangs = HangWatchdog.hangCount(forScene: resizeScene) - initialResizeHangCount
        PerfScene.current = "app"
        // Finite Debug-build stalls are reported, but the runner's hard failures
        // are the regression signals for this journey: a nonzero/crash exit,
        // missing round completion, or SwiftUI/AppKit diagnostics in stderr.
        // Sampling itself can extend a >150 ms Debug layout pulse, so treating
        // every watchdog sample as a failed crash regression creates a feedback
        // loop in the harness rather than testing liveness.
        cleanupHarness()
        pickerStressLog("PICKER_STRESS COMPLETE rounds=\(rounds) pickerWatchdogHangs=\(hangs) resizeWatchdogHangs=\(resizeHangs)")
        NSApp.terminate(nil)
    }

    private func pickerStressProjectFromEnvironment() -> DiscoveredProject? {
        guard let path = ProcessInfo.processInfo.environment["AGENTDECK_PICKER_STRESS_PROJECT_PATH"],
              !path.isEmpty,
              path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return ProjectDiscovery()
            .discoverProjects(rootDirectoryURLs: [], additionalProjectPaths: [url.path])
            .first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
    }

    private func waitForPickerStressCard(
        sessionID: UUID,
        expanded: Bool,
        rowSource: PickerStressRowSource,
        afterCatalogGeometryRevision: Int
    ) async -> Bool {
        for _ in 0..<20 {
            let acknowledgements = pickerStressAcknowledgements
            if acknowledgements.sessionID == sessionID,
               acknowledgements.mounted,
               acknowledgements.rowSource == rowSource,
               acknowledgements.catalogGeometryRevision > afterCatalogGeometryRevision,
               acknowledgements.rowCount > 0,
               acknowledgements.expanded == expanded,
               acknowledgements.cardSize.width > 0,
               (!expanded || acknowledgements.catalogSize.height > 100) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func pickerStressCatalogHeightIsApproximately(_ expected: CGFloat) -> Bool {
        abs(pickerStressAcknowledgements.catalogSize.height - expected) <= 2
    }

    private func pickerStressSizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private func pickerStressLog(_ line: String) {
        fputs(line + "\n", stderr)
        TranscriptScrollProfiler.fileLog(line)
    }
#endif

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        var map: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions where sessionActivityCache[session.id] != nil {
            map[session.id] = sessionActivityCache[session.id]
        }
        return map
    }

    private var activeLoopSessionIDs: Set<UUID> {
        activeLoopSessionIDs(in: visibleSessions)
    }

    private func activeLoopSessionIDs(in sessions: [PiAgentSessionRecord]) -> Set<UUID> {
        let sessionIDs = Set(sessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            sessionIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }

    // The active column's dynamic cards must not feed transient intrinsic minima
    // back into the enclosing split-view child during a resize pass.
    private var activeSessionPaneBoundary: some View {
        Color.clear
            .frame(minWidth: 360, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                activeSessionColumn
            }
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, TranscriptFloatingControlGeometry.transcriptHorizontalPadding)
                    // Suppress the edge-fade `.mask` while a splitter drag is
                    // active: its gradient smears into a full-column blur mask
                    // until the table re-lays out to the settled width.
                    .transcriptEdgeFade(enabled: !isColumnResizing)

                // NOTE: the old opaque "settle cover" (spinner shown over the
                // transcript on every session switch) is gone. The switch is now
                // correct on its first frame — the coordinator holds the previous
                // transcript until the new one is decoded, then measures the
                // visible rows synchronously before pinning — so hiding the table
                // behind a spinner only ADDED a flash of loading state per click.

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out. Isolated in its own view that observes
                // `transcriptPinnedState` so toggling the pill never re-evaluates this
                // screen's body (and never re-runs the transcript items build).
                JumpToLatestOverlay(pinnedState: transcriptPinnedState) {
                    requestTranscriptBottomScroll()
                }
            }
            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                // Shown for project drafts, including subagents-off — the card
                // renders dimmed with its switch so agents can be turned back
                // on right here instead of from the Agents screen. General Chat
                // never exposes Deck-agent delegation.
                if let session = store.selectedSession,
                   !session.isNoProject,
                   session.status == .draft,
                   store.activeLoopRun(for: session.id) == nil {
#if DEBUG
                    PiAgentSessionSubagentPickerCard(
                        viewModel: viewModel,
                        session: session,
                        stressExpansionRequest: isPickerStressRequested ? pickerStressExpansionRequest : nil,
                        stressRowSource: isPickerStressRequested ? pickerStressRowSource : nil,
                        stressAcknowledgements: isPickerStressRequested ? pickerStressAcknowledgements : nil
                    )
                    .id(session.id)
#else
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
#endif
                }

                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                } else if let request = selectedPendingSupervisorRequest {
                    PiSubagentSupervisorRequestInlineNotice(
                        request: request,
                        onRespond: { isSupervisorRequestSheetPresented = true },
                        onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: request.parentSessionID) }
                    )
                }

                PiAgentComposerPanel(
                    viewModel: viewModel,
                    store: store,
                    selectedSessionID: store.selectedSessionID,
                    onWillSend: beginTranscriptAutoScrollTurn,
                    onDidSend: requestTranscriptBottomScroll
                )
                .equatable()
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: sessionKindTagColor(session.kind))
                    if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                            Text(LanguageStore.shared.t("agent.chatWith", agentName))
                                .font(AppTheme.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.12)))
                    }
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                Text(session.displayTitle)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let error = session.lastError {
                    Text(error)
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: LanguageStore.shared.t("agent.noSessionTitle")) {
                Text(LanguageStore.shared.t("agent.noSessionBody"))
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var transcript: some View {
        // `PiAgentTranscriptHost` is the ONLY view that observes `transcriptCache`,
        // so the ~30Hz streaming pulse re-renders the transcript table alone and no
        // longer invalidates this screen's session list / composer. `makeItems` is
        // re-run inside the host on each pulse; it reads the live cache + parent
        // references (store/viewModel), so the items stay correct even though the
        // parent struct it captured isn't re-evaluated between pulses.
        PiAgentTranscriptHost(
            cache: transcriptCache,
            sessionID: store.selectedSession?.id,
            isTranscriptLoading: { [store] in store.isSelectedTranscriptLoading },
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptPinnedState.isPinned = isPinnedToBottom
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptPinnedState.isPinned else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

    private var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        // Hidden tab: don't rebuild on streaming pulses. The screen stays mounted
        // (so the table is never torn down), but returning the last-built rows means
        // a backgrounded streaming session does no per-tick transcript work. The
        // next pulse after becoming active rebuilds to current content.
        if !isActive { return transcriptCache.memoizedTranscriptItems }
        return TranscriptScrollProfiler.measureBody("itemsBuild") {
            // `makeItems` is re-run on every host body pass — cache pulses, but also
            // scroll-time re-evaluations that don't change the transcript at all.
            // Skip the O(N) rebuild when no input changed: compute a cheap signature
            // and reuse the last array on a match. The signature reads every input the
            // build does, so it can never serve stale content.
            let signature = appKitTranscriptItemsSignature
            if transcriptCache.memoizedTranscriptItemsSignature == signature {
                return transcriptCache.memoizedTranscriptItems
            }
#if DEBUG
            debugLogItemsBuildTrigger()
#endif
            let items = appKitTranscriptItemsBuild
            transcriptCache.memoizedTranscriptItems = items
            transcriptCache.memoizedTranscriptItemsSignature = signature
            return items
        }
    }

    /// COMPLETE signature of every input `appKitTranscriptItemsBuild` reads.
    /// `renderRevision`/`streamingRevision` cover all transcript content (threads).
    /// `appKitTranscript{Chrome,ThreadContext}Revision` are the SAME hashes the build
    /// folds into each row's `contentRevision`, so reusing them here captures the
    /// session-level inputs (status, worktree/project, loading, visibility, skills,
    /// subagent summary) without re-listing them — and can't drift if those helpers
    /// gain a read. The tail adds the few inputs those revisions don't cover.
    private var appKitTranscriptItemsSignature: Int {
        let snapshot = transcriptTimelineSnapshot
        var hasher = Hasher()
        hasher.combine(transcriptCache.renderRevision)
        hasher.combine(transcriptCache.streamingRevision)
        hasher.combine(appKitTranscriptChromeRevision(snapshot: snapshot))
        hasher.combine(appKitTranscriptThreadContextRevision(snapshot: snapshot))
        hasher.combine(showArchivedPreCompactionTranscript)
        if let session = store.selectedSession {
            hasher.combine(viewModel.displayAgentsRevision)
            hasher.combine(session.commandInvocations)         // slash-command chrome
            hasher.combine(session.forkedFromParentTitle)      // fork-origin card
            hasher.combine(session.forkedFromSessionID)
            hasher.combine(session.forkedFromTranscriptSnapshot)
            // Full run/request records can be large (nested child records, output,
            // timestamps). Hashing them on every SwiftUI body pass showed up in
            // itemsBuild hitch stacks. The store revisions are bumped on every
            // mutation, so they keep descriptor memoization correct without the
            // per-pass deep Hashable walk.
            hasher.combine(store.subagentRunsRevision)
            hasher.combine(store.supervisorRequestsRevision)
        }
        return hasher.finalize()
    }

#if DEBUG
    /// Names which memo input invalidated `appKitTranscriptItems` — the labels
    /// mirror `appKitTranscriptItemsSignature` (with the chrome/context hashes
    /// split into their fields) so an unexplained rebuild on an idle session can
    /// be attributed straight from the console. Runs only on a memo miss.
    private func debugLogItemsBuildTrigger() {
        var components: [String: Int] = [
            "render": transcriptCache.renderRevision,
            "streaming": transcriptCache.streamingRevision,
            "archived": showArchivedPreCompactionTranscript ? 1 : 0,
            "visibility": String(describing: viewModel.appSettings.piAgentTranscriptVisibility).hashValue,
            "skills": visibleSkillsForSelectedSession.map(\.name).hashValue,
            "agents": viewModel.displayAgentsRevision,
            "userProfile": viewModel.appSettings.userDisplayName.hashValue ^ (viewModel.appSettings.userAvatarFileName?.hashValue ?? 0)
        ]
        if let session = store.selectedSession {
            components["sessionID"] = session.id.hashValue
            components["status"] = String(describing: session.status).hashValue
            components["loading"] = store.isSelectedTranscriptLoading ? 1 : 0
            components["path"] = (session.worktreePath ?? session.projectPath).hashValue
            components["command"] = session.commandInvocations.hashValue
            var forkHasher = Hasher()
            forkHasher.combine(session.forkedFromParentTitle)
            forkHasher.combine(session.forkedFromSessionID)
            forkHasher.combine(session.forkedFromTranscriptSnapshot)
            components["fork"] = forkHasher.finalize()
            components["runs"] = store.subagentRunsRevision
            components["requests"] = store.supervisorRequestsRevision
        }
        let previous = transcriptCache.lastItemsBuildComponents
        transcriptCache.lastItemsBuildComponents = components
        guard !previous.isEmpty else { return }
        let changed = Set(components.keys).union(previous.keys).filter { components[$0] != previous[$0] }.sorted()
        guard !changed.isEmpty else { return }
        guard TranscriptScrollProfiler.verboseTrace else { return }
        TranscriptScrollProfiler.logger.error("itemsBuild trigger — changed inputs: \(changed.joined(separator: ","), privacy: .public)")
    }
#endif

    private var appKitTranscriptItemsBuild: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision(snapshot: timelineSnapshot)
        let contextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        let visibility = viewModel.appSettings.piAgentTranscriptVisibility
        let skills = visibleSkillsForSelectedSession
        let commandSlashNames = Set((store.selectedSession?.commandInvocations ?? []).map { name in
            name.hasPrefix("/") ? String(name.dropFirst()) : name
        })
        let subagentRuns = nativeSubagentRunsByID
        var agentProfilesByName: [String: EffectiveAgentRecord] = [:]
        for agent in viewModel.cachedAllDisplayAgents {
            agentProfilesByName[agent.name] = agent
        }
        if let session = store.selectedSession {
            for agent in viewModel.catalogAgents(for: session) {
                agentProfilesByName[agent.name] = agent
            }
        }

        var descriptors: [PiAgentTranscriptBlockDescriptor] = []
        // Block ids whose render kind we memoize this pass (the per-N timeline
        // rows). Used to prune the kind cache to the visible transcript below.
        var memoizedBlockIDs: Set<String> = []

        // --- Chrome rows (each its own revision) ---
        if let session = store.selectedSession {
            if visibility.showShortcutsStrip {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "shortcuts-strip-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeShortcutsStripView.self) { view, width in view.configure(width: width) }),
                    baseRevision: 0,
                    estimatedContentHeight: { _ in 40 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            if let parentTitle = session.forkedFromParentTitle, !parentTitle.isEmpty {
                let parentID = session.forkedFromSessionID
                let snapshot = session.forkedFromTranscriptSnapshot
                let onSelect: (UUID) -> Void = { parentSessionID in
                    viewModel.selectPiAgentSession(parentSessionID)
                }
                var hasher = Hasher()
                hasher.combine(parentTitle)
                hasher.combine(parentID)
                hasher.combine(snapshot)
                let forkPayload = NativeForkOriginPayload.make(
                    parentTitle: parentTitle, parentSessionID: parentID,
                    transcriptSnapshot: snapshot, onSelectParent: onSelect)
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "fork-origin-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeForkOriginCardView.self) { view, width in
                        view.configure(payload: forkPayload, width: width)
                    }),
                    baseRevision: hasher.finalize(),
                    estimatedContentHeight: { _ in 70 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            // The final system prompt is no longer a transcript card — it's a
            // toolbar button (next to Plan / Session Resources / Transcript Display)
            // that opens the same text popover. See `piAgentPrimaryToolbarContent`.
        }

        if let archive = timelineSnapshot.preCompactionArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.compactedAt)
            let isShowing = showArchivedPreCompactionTranscript
            let archivePayload = NativeArchiveNoticePayload.preCompaction(
                hiddenCount: archive.hiddenCount, compactedAt: archive.compactedAt,
                isShowing: isShowing, onToggle: { showArchivedPreCompactionTranscript.toggle() })
            hasher.combine(isShowing)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pre-compaction-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: archivePayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }
        if let archive = timelineSnapshot.recentWindowArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.limit)
            let recentPayload = NativeArchiveNoticePayload.recentWindow(
                hiddenCount: archive.hiddenCount, limit: archive.limit,
                onOpen: { isEarlierTranscriptSheetPresented = true })
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "recent-window-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: recentPayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }

        // --- Timeline rows: each thread flattens into one row per block ---
        if store.isSelectedTranscriptLoading && timelineItems.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .loading(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 80 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else if timelineItems.isEmpty && descriptors.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .empty(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 120 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else {
            for item in timelineItems {
                switch item.kind {
                case let .thread(thread):
                    if let question = thread.question {
                        let blockID = "q-\(item.id)"
                        let revision = appKitQuestionBlockRevision(question, contextRevision: contextRevision)
                        memoizedBlockIDs.insert(blockID)
                        // Native fast path for plain-text questions (no attachment
                        // Chip-bearing questions use the dedicated chip-aware card;
                        // plain questions use the lighter bubble.
                        let questionKind = transcriptCache.cachedBlockKind(id: blockID, revision: revision) {
                            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                                for: question, skills: skills, commandSlashNames: commandSlashNames) > 0
                            return hasChips
                                ? nativeChipQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                                : nativeQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames, showImages: visibility.showImages)
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: nil,
                            kind: questionKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            questionNavigationTitle: Self.questionNavigationTitle(for: question),
                            isThreadQuestion: true
                        ))
                    }
                    let projectPath = store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns,
                        projectPath: projectPath
                    ) {
                        // Native rendering for the supported child types; the
                        // rest (tool groups, subagent/memory cards) still hosted.
                        let revision = appKitChildBlockRevision(child, contextRevision: contextRevision, subagentRuns: subagentRuns)
                        let toolGroupEstimateModel: NativeToolGroupModel? = {
                            guard case let .toolGroup(group) = child else { return nil }
                            return NativeToolGroupModel.make(group: group, visibility: visibility, projectPath: projectPath)
                        }()
                        memoizedBlockIDs.insert(child.id)
                        let nativeKind = transcriptCache.cachedBlockKind(id: child.id, revision: revision) {
                            nativeChildKind(
                                for: child, visibility: visibility, skills: skills,
                                commandSlashNames: commandSlashNames,
                                subagentRuns: subagentRuns,
                                agentProfilesByName: agentProfilesByName
                            ) ?? Self.nativeEmptyKind
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: nil,
                            kind: nativeKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0, toolGroupModel: toolGroupEstimateModel) },
                            threadID: item.id,
                            isThreadQuestion: false
                        ))
                    }
                }
            }
        }

        // Bottom anchor — a 1pt row scrollToBottom can always land on.
        descriptors.append(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-bottom-anchor",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { _, _ in }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 1 },
            threadID: nil,
            isThreadQuestion: false
        ))

        // --- Inset pass: NSTableView intercell spacing is uniform, so split
        // each inter-row gap in half across the two adjacent rows. Gaps come from
        // the design system: question↔reply (threadSpacing), sibling children
        // (childSpacing), everything else (rowSpacing). ---
        if descriptors.count > 1 {
            for i in 0 ..< descriptors.count - 1 {
                let gap: CGFloat
                if let tid = descriptors[i].threadID, tid == descriptors[i + 1].threadID {
                    gap = descriptors[i].isThreadQuestion ? AppTheme.Chat.threadSpacing : AppTheme.Chat.childSpacing
                } else {
                    gap = AppTheme.Chat.rowSpacing
                }
                descriptors[i].bottomInset += gap / 2
                descriptors[i + 1].topInset += gap / 2
            }
        }

        // Match the old NSScrollView top inset as an actual row so new/small
        // transcripts do not start inside the SwiftUI top fade before scrolling.
        // Insert after the inter-row gap pass so this adds exactly 18pt and no
        // extra row spacing before the shortcuts/first message.
        descriptors.insert(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-top-fade-spacer",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 18 }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 18 },
            threadID: nil,
            isThreadQuestion: false
        ), at: 0)

        transcriptCache.pruneBlockKindCache(keeping: memoizedBlockIDs)

        // --- Materialize: fold insets into the revision (so an inset change
        // re-tiles the row) and into the height estimate. ---
        return descriptors.map { descriptor in
            var revisionHasher = Hasher()
            revisionHasher.combine(descriptor.baseRevision)
            revisionHasher.combine(descriptor.topInset)
            revisionHasher.combine(descriptor.bottomInset)
            let topInset = descriptor.topInset
            let bottomInset = descriptor.bottomInset
            let contentEstimate = descriptor.estimatedContentHeight
            let kind = descriptor.kind ?? Self.nativeEmptyKind
            return PiAgentAppKitTranscriptItem(
                id: descriptor.id,
                kind: kind,
                contentRevision: revisionHasher.finalize(),
                questionNavigationTitle: descriptor.questionNavigationTitle,
                topInset: topInset,
                bottomInset: bottomInset,
                estimatedHeight: { width in contentEstimate(width) + topInset + bottomInset }
            )
        }
    }

    /// Builds one block of a thread (question or a single child) as its own
    /// row view, via `PiAgentTranscriptThreadCard`'s `renderMode` — the card
    /// view is byte-identical to the full-thread rendering, just sliced to one
    /// `ThreadMessageRow`.
    private func threadBlockCard(
        thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        projectPath: String?,
        subagentRuns: [UUID: PiSubagentRunRecord],
        renderMode: PiAgentTranscriptThreadCard.RenderMode,
        blockID: String
    ) -> some View {
        let viewModel = viewModel
        return PiAgentTranscriptThreadCard(
            thread: thread,
            visibility: visibility,
            skills: skills,
            commandSlashNames: commandSlashNames,
            projectPath: projectPath,
            nativeSubagentRunsByID: subagentRuns,
            nativeSubagentCard: nativeSubagentCard,
            renderMode: renderMode,
            onFork: { entry in viewModel.forkPiAgentSession(from: entry) },
            forkAgentChoices: forkAgentChoicesForSelectedSession,
            onForkAsAgentChat: { entry, agent in
                viewModel.forkPiAgentSessionAsAgentChat(from: entry, agent: agent)
            }
        )
        .id(blockID)
    }

    /// Native payload for a plain-text user question (no attachment chips):
    /// hugged-width right-aligned bubble with leading copy + fork affordance.
    /// Instance method because the fork actions capture `viewModel`.
    /// The fork affordance for a user-question row (Pi session + per-agent chat).
    private func questionForkModel(_ question: PiAgentTranscriptEntry) -> ForkModel {
        let agentOptions: [ForkAgentOption] = (forkAgentChoicesForSelectedSession ?? []).map { agent in
            ForkAgentOption(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { [viewModel] in viewModel.forkPiAgentSessionAsAgentChat(from: question, agent: agent) }
            )
        }
        return ForkModel(
            onForkSession: { [viewModel] in viewModel.forkPiAgentSession(from: question) },
            onRerun: { [viewModel] in viewModel.rerunPiAgentSession(from: question) },
            agentOptions: agentOptions
        )
    }

    /// Native render kind for a chip-bearing user question (skill/command/
    /// attachment chips) — the dedicated chip-aware question card.
    private func nativeChipQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        // The ForkModel is cheap (it just wraps closures), so build it eagerly.
        // The payload parse (message text + chip extraction regex + folder
        // existence checks) is deferred into the configure closure so it runs only
        // when a cell actually configures — i.e. for visible rows — instead of for
        // every question on every `itemsBuild` pulse.
        let fork = questionForkModel(question)
        let userTitle = viewModel.resolvedUserDisplayName
        let userAvatar = UserAvatarStore.loadImage(fileName: viewModel.appSettings.userAvatarFileName)
        return .native(.of(PiAgentNativeQuestionView.self) { view, width in
            var payload = NativeQuestionPayload.make(
                entry: question, skills: skills, commandSlashNames: commandSlashNames, fork: fork)
            payload.headerTitle = userTitle
            payload.headerAvatarImage = userAvatar
            view.configure(payload: payload, width: width)
        })
    }

    private func nativeQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        showImages: Bool
    ) -> PiAgentTranscriptCellKind {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: question, skills: skills, commandSlashNames: commandSlashNames)
        let fork = questionForkModel(question)
        return .bubble(NativeBubblePayload(
            role: .user,
            headerTitle: viewModel.resolvedUserDisplayName,
            iconSymbol: "person.crop.circle",
            headerAvatarImage: UserAvatarStore.loadImage(fileName: viewModel.appSettings.userAvatarFileName),
            markdownSource: text,
            imageReferences: question.imageReferences,
            showInlineImagePreviews: showImages,
            bodyPrefix: nil,
            copyText: question.text,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true,
            fork: fork
        ))
    }

    private static func questionNavigationTitle(for entry: PiAgentTranscriptEntry) -> String {
        let collapsed = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "User message" }
        return collapsed
    }

    /// Per-block height estimators — character-count math, no SwiftUI pass.
    /// Mirror the heights the old per-thread estimator summed per child.
    private static func estimatedQuestionHeight(_ entry: PiAgentTranscriptEntry, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
        return CGFloat(lines) * 18 + 56
    }

    /// Native render kind for a thread child, or nil to fall back to the hosted
    /// SwiftUI path. Tool groups and subagent/memory status cards stay hosted
    /// (later stages); everything else renders natively.
    /// A native 0-height empty row — the safety fallback now that every descriptor
    /// is native (no `.hosted` path remains).
    private static let nativeEmptyKind: PiAgentTranscriptCellKind =
        .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })

#if DEBUG
    private static let nativeToolGroupLog = Logger(subsystem: "works.earendil.pi-deck", category: "NativeToolGroup")
#endif

    private func nativeChildKind(
        for child: PiAgentThreadChild,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        subagentRuns: [UUID: PiSubagentRunRecord],
        agentProfilesByName: [String: EffectiveAgentRecord]
    ) -> PiAgentTranscriptCellKind? {
        switch child {
        case .assistant:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .thinking:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .steering(let entry):
            // Steering messages and structured Ask User answers remain
            // right-aligned user-authored content, but have distinct labels.
            let headerTitle = entry.isNativeAskResponse ? "Answer" : "Steering"
            let headerIcon = entry.isNativeAskResponse
                ? "questionmark.bubble.fill"
                : "arrowshape.turn.up.forward.circle"
            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                for: entry, skills: skills, commandSlashNames: commandSlashNames) > 0
            if hasChips {
                var payload = NativeQuestionPayload.make(
                    entry: entry, skills: skills, commandSlashNames: commandSlashNames, fork: nil)
                payload.headerTitle = headerTitle
                payload.headerIcon = headerIcon
                return .native(.of(PiAgentNativeQuestionView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let text = PiAgentUserMessageContent.displayMessageText(
                for: entry, skills: skills, commandSlashNames: commandSlashNames)
            return .bubble(NativeBubblePayload(
                role: .user,
                headerTitle: headerTitle,
                iconSymbol: headerIcon,
                markdownSource: text,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: visibility.showImages,
                bodyPrefix: nil,
                copyText: entry.text,
                copySide: .leading,
                isThreadChild: false,
                isUserHugged: true
            ))
        case .status(let entry):
            if let recapMarker = LoopRunRecapCodec.decode(from: entry) {
                let payload = NativeLoopRecapPayload.make(entry: entry, marker: recapMarker)
                return .native(.of(PiAgentNativeLoopRecapCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if LoopRunTranscriptCodec.decode(from: entry) != nil {
                return Self.nativeEmptyKind
            }
            if let memoryEvent = entry.agentMemoryEvent {
                let payload = NativeMemoryCardPayload.make(event: memoryEvent)
                return .native(.of(PiAgentNativeMemoryCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                if NativeSubagentFactory.isParallel(run) {
                    let payload = NativeSubagentParallelPayload.make(
                        run: run,
                        agentsByName: agentProfilesByName,
                        imageStore: viewModel.agentImageStore,
                        onOpenChildTranscript: { [self] in selectedSubagentTranscriptRunID = $0 },
                        onStopChild: { [viewModel] in viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) }
                    )
                    return .native(.of(PiAgentNativeSubagentParallelCardView.self) { view, width in
                        view.configure(payload: payload, width: width)
                    })
                }
                let payload = NativeAgentBlockPayload.makeSingle(
                    run: run,
                    agent: agentProfilesByName[run.agentName],
                    imageStore: viewModel.agentImageStore,
                    onStop: { [viewModel] in viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
                    onTranscript: { [self] in selectedSubagentTranscriptRunID = run.id },
                    onReveal: { [self] in revealSubagentRun(run) }
                )
                return .native(.of(PiAgentNativeSubagentRunCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            // Soft system notices (extension notify / compaction) — separate muted cards.
            if let notice = NativeSystemNoticePayload.make(for: entry) {
                return .native(.of(PiAgentNativeSystemNoticeView.self) { view, width in
                    view.configure(payload: notice, width: width)
                })
            }
            // "System Prompt Captured" / "Subagent Started" render as a native
            // status row with prompt-audit buttons (computed in make(for:)).
            if entry.isDividerStatus {
                let payload = NativeDividerPayload.make(for: entry)
                return .native(.of(PiAgentNativeStatusDividerView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .error(let entry):
            // Fatal model/provider errors get the richer error row (fixed "Error"
            // headline + full message as the detail body); per-tool failures keep
            // the compact row.
            if entry.isModelError {
                let payload = NativeErrorPayload.make(for: entry)
                return .native(.of(PiAgentNativeErrorRowView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .retry(let entry, let info):
            let payload = NativeRetryPayload.make(info: info, timestamp: entry.timestamp)
            return .native(.of(PiAgentNativeRetryRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .toolGroup(let group):
            guard let model = NativeToolGroupModel.make(
                group: group,
                visibility: visibility,
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
            ) else {
#if DEBUG
                assertionFailure("Visible native tool group produced no display model: \(group.id)")
                Self.nativeToolGroupLog.error("Visible native tool group produced no display model: \(group.id.uuidString, privacy: .public)")
#endif
                return Self.nativeEmptyKind
            }
            return .native(.of(PiAgentNativeToolGroupView.self) { view, width in
                view.configure(model: model, width: width)
            })
        }
    }

    /// Maps a thread child to a native bubble payload for the plain-text reply
    /// rows (assistant / thinking). Returns nil for anything that still renders
    /// through the hosted SwiftUI path (subagent summaries, tool groups, status,
    /// errors, retries, steering — handled in later stages).
    private func nativeReplyPayload(for child: PiAgentThreadChild, showImages: Bool) -> NativeBubblePayload? {
        switch child {
        case .assistant(let entry):
            let text = TextSanitizer.sanitizeAnswer(entry.text)
            return NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: text,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
                bodyPrefix: nil,
                copyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                copySide: .trailing,
                isThreadChild: true
            )
        case .thinking(let entry):
            let display = TextSanitizer.sanitizeThinking(entry.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return NativeBubblePayload(
                role: .thinking,
                headerTitle: entry.title,
                iconSymbol: "brain.head.profile",
                markdownSource: display.isEmpty ? "Pi has not emitted reasoning text yet." : display,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
                bodyPrefix: nil,
                copyText: display,
                copySide: .trailing,
                isThreadChild: true
            )
        default:
            return nil
        }
    }

    private static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat, toolGroupModel: NativeToolGroupModel? = nil) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case .toolGroup:
            // Estimate from the same capped display model the native tool card
            // renders, not from raw activity count. MCP/web/diff groups can contain
            // many underlying updates while displaying only a compact card.
            return toolGroupModel?.estimatedContentHeight(forWidth: width) ?? 1
        case .status, .error, .retry:
            return 56
        }
    }

    /// Content revision for a question block — only that entry + context.
    private func appKitQuestionBlockRevision(_ entry: PiAgentTranscriptEntry, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hashEntryRevision(entry, into: &hasher)
        return hasher.finalize()
    }

    /// Content revision for a child block — only that child's entry/entries +
    /// context. A sibling streaming does not bump this, so only the streaming
    /// block's row reconfigures.
    private func appKitChildBlockRevision(
        _ child: PiAgentThreadChild,
        contextRevision: Int,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        switch child {
        case let .steering(entry), let .thinking(entry), let .assistant(entry),
             let .error(entry):
            hashEntryRevision(entry, into: &hasher)
        case let .status(entry):
            hashEntryRevision(entry, into: &hasher)
            // A status child fronting a Deck agent run renders the whole run
            // record (status, children, durations, results) — fold exactly that
            // run in so ONLY this row re-renders as the run streams. This is the
            // narrow replacement for the all-rows run hash that used to live in
            // the shared context revision above.
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                hasher.combine(run)
            }
        case let .retry(entry, _):
            hashEntryRevision(entry, into: &hasher)
        case let .toolGroup(group):
            hasher.combine(group.id)
            for entry in group.entries { hashEntryRevision(entry, into: &hasher) }
            for activity in group.activities {
                hasher.combine(activity.id)
                hasher.combine(activity.entries.count)
                hashEntryRevision(activity.representativeEntry, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    private func appKitTranscriptChromeRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(store.selectedSession?.id)
        hasher.combine(String(describing: store.selectedSession?.status))
        hasher.combine(store.isSelectedTranscriptLoading)
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(viewModel.appSettings.userDisplayName)
        hasher.combine(viewModel.appSettings.userAvatarFileName)
        return hasher.finalize()
    }

    private func appKitTranscriptThreadContextRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(viewModel.displayAgentsRevision)
        hasher.combine(store.selectedSession.map { $0.worktreePath ?? $0.projectPath })
        // Deliberately NO subagent-run state here: this revision folds into EVERY
        // row, and run records update on every subagent event — hashing them here
        // invalidated the whole transcript (full itemsBuild + visible reconfigure)
        // several times a second for the entire run (steady 40-80ms hitches). The
        // one row that renders a run folds its own record in via
        // `appKitChildBlockRevision`; the itemsBuild memo signature still hashes
        // all runs, so the descriptor list itself can never go stale.
        return hasher.finalize()
    }

    private func appKitTranscriptContentRevision(
        for item: PiAgentTranscriptTimelineItem,
        snapshot: PiAgentTranscriptTimelineSnapshot,
        contextRevision: Int
    ) -> Int {
        switch item.kind {
        case let .thread(thread):
            let signature = cheapThreadSignature(thread, contextRevision: contextRevision)
            return transcriptCache.cachedThreadRevision(for: thread.id, signature: signature) {
                var hasher = Hasher()
                hasher.combine(contextRevision)
                hashThreadRevision(thread, into: &hasher)
                return hasher.finalize()
            }
        }
    }

    // Cache key for a thread's content revision. Hashes only (id, text.count) per entry —
    // about 3× cheaper than the full revision hash. Covers any mutation upsert/updateEntry
    // can make to a known entry, not just append-only streaming growth, so reusing the
    // cached full hash is safe whenever this signature is unchanged.
    private func cheapThreadSignature(
        _ thread: PiAgentTranscriptThread,
        contextRevision: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hasher.combine(thread.id)
        inlineEntrySignature(thread.question, into: &hasher)
        hasher.combine(thread.steeringMessages.count)
        for entry in thread.steeringMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.thinkingParts.count)
        for entry in thread.thinkingParts { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.assistantMessages.count)
        for entry in thread.assistantMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.activities.count)
        for activity in thread.activities {
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            inlineEntrySignature(activity.representativeEntry, into: &hasher)
        }
        hasher.combine(thread.statuses.count)
        for entry in thread.statuses { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.errors.count)
        for entry in thread.errors { inlineEntrySignature(entry, into: &hasher) }
        return hasher.finalize()
    }

    private func inlineEntrySignature(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.imageReferences)
    }

    private func hashThreadRevision(_ thread: PiAgentTranscriptThread, into hasher: inout Hasher) {
        hasher.combine(thread.id)
        hashEntryRevision(thread.question, into: &hasher)
        thread.steeringMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.thinkingParts.forEach { hashEntryRevision($0, into: &hasher) }
        thread.assistantMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.activities.forEach { activity in
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            hashEntryRevision(activity.representativeEntry, into: &hasher)
        }
        thread.statuses.forEach { hashEntryRevision($0, into: &hasher) }
        thread.errors.forEach { hashEntryRevision($0, into: &hasher) }
    }

    private func hashEntryRevision(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.imageReferences)
        hasher.combine(entry.timestamp)
    }


    private var loadingTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                AppSpinner()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.loadingTranscript"))
                        .font(AppTheme.Font.headline)
                    Text(LanguageStore.shared.t("agent.loadingTranscriptBody"))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var emptyTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.noTranscriptTitle"))
                        .font(AppTheme.Font.headline)
                    Text(LanguageStore.shared.t("agent.noTranscriptBody"))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var transcriptTimelineSnapshot: PiAgentTranscriptTimelineSnapshot {
        let items = transcriptTimelineItems
        let archiveRange = preCompactionArchiveRange(in: items)
        let archiveNotice = archiveRange.flatMap { archive -> (hiddenCount: Int, compactedAt: Date)? in
            archive.visibleStartIndex > 0 ? (archive.visibleStartIndex, archive.compactedAt) : nil
        }
        let visibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript, let archiveRange {
            visibleItems = Array(items[archiveRange.visibleStartIndex...])
        } else {
            visibleItems = items
        }
        let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
        let mainVisibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript && visibleItems.count > recentTranscriptTimelineItemLimit {
            earlierVisibleItems = Array(visibleItems.dropLast(recentTranscriptTimelineItemLimit))
            mainVisibleItems = Array(visibleItems.suffix(recentTranscriptTimelineItemLimit))
        } else {
            earlierVisibleItems = []
            mainVisibleItems = visibleItems
        }
        let recentWindowArchive = earlierVisibleItems.isEmpty
            ? nil
            : (hiddenCount: earlierVisibleItems.count, limit: recentTranscriptTimelineItemLimit)
        return PiAgentTranscriptTimelineSnapshot(
            allItems: items,
            visibleItems: visibleItems,
            mainVisibleItems: mainVisibleItems,
            earlierVisibleItems: earlierVisibleItems,
            preCompactionArchive: archiveNotice,
            recentWindowArchive: recentWindowArchive
        )
    }

    private var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        let items = transcriptCache.threads.map { thread in
            PiAgentTranscriptTimelineItem(
                id: "thread-\(thread.id.uuidString)",
                timestamp: thread.timelineTimestamp,
                kind: .thread(thread)
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private var visibleTranscriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        transcriptTimelineSnapshot.mainVisibleItems
    }

    private var preCompactionArchiveNotice: (hiddenCount: Int, compactedAt: Date)? {
        transcriptTimelineSnapshot.preCompactionArchive
    }

    private func preCompactionArchiveRange(in items: [PiAgentTranscriptTimelineItem]) -> (visibleStartIndex: Int, compactedAt: Date)? {
        guard let index = items.indices.last(where: { index in
            guard case let .thread(thread) = items[index].kind else { return false }
            return thread.statuses.contains(where: isCompletedCompactionEntry)
        }) else { return nil }
        return (index, items[index].timestamp)
    }

    private func isCompletedCompactionEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        guard entry.title == "Compaction" else { return false }
        let text = entry.text.localizedLowercase
        return (text.contains("context compacted") || text.contains("compaction complete") || text.contains("compaction finished"))
            && !text.contains("nothing to compact")
            && !text.contains("compacting")
    }

    @ViewBuilder
    private func preCompactionArchiveCard(_ archive: (hiddenCount: Int, compactedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showArchivedPreCompactionTranscript ? "tray.and.arrow.up" : "archivebox")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(AppTheme.Font.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? LanguageStore.shared.t("agent.hide") : LanguageStore.shared.t("agent.loadEarlier")) {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func recentWindowArchiveCard(_ archive: (hiddenCount: Int, limit: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text(LanguageStore.shared.t("agent.earlierHidden"))
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text(LanguageStore.shared.t("agent.showingLatestFmt2", archive.limit, archive.hiddenCount))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
            Button(LanguageStore.shared.t("agent.openEarlier")) {
                isEarlierTranscriptSheetPresented = true
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var earlierTranscriptSheet: some View {
        let snapshot = transcriptTimelineSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.earlierTitle"))
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text(LanguageStore.shared.t("agent.earlierBody", recentTranscriptTimelineItemLimit))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(LanguageStore.shared.t("common.done")) {
                    isEarlierTranscriptSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView(showsIndicators: false) {
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.earlierVisibleItems) { item in
                        transcriptTimelineItemView(item, snapshot: snapshot)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    private func transcriptTimelineItemView(_ item: PiAgentTranscriptTimelineItem, snapshot: PiAgentTranscriptTimelineSnapshot) -> some View {
        switch item.kind {
        case let .thread(thread):
            PiAgentTranscriptThreadCard(
                thread: thread,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                skills: visibleSkillsForSelectedSession,
                commandSlashNames: Set((store.selectedSession?.commandInvocations ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }),
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
            .id(item.id)
        }
    }

    private func updateStabilizedProcessingMessage(_ message: String?) {
        processingMessageUpdateTask?.cancel()
        processingMessageUpdateTask = nil

        guard let message else {
            stabilizedProcessingMessage = nil
            return
        }

        guard stabilizedProcessingMessage != nil else {
            stabilizedProcessingMessage = message
            return
        }

        processingMessageUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            stabilizedProcessingMessage = message
            processingMessageUpdateTask = nil
        }
    }

    private var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }
        if let subagentMessage = runningSubagentsProcessingMessage(for: session) {
            return subagentMessage
        }

        // The RPC-derived activity knows exactly what Pi is doing this instant —
        // it distinguishes a running tool from a finished one and reasoning from
        // an empty turn-start placeholder, neither of which the transcript can.
        if let activity = store.processingActivity(for: session.id) {
            return processingMessage(for: activity)
        }

        // Fallback for a session that is active but has no live activity yet
        // (e.g. just reattached): infer from the last transcript entry.
        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Working"
    }

    private func processingMessage(for activity: PiAgentProcessingActivity) -> String {
        switch activity {
        case .preparing: return "Preparing response"
        case .reasoning: return "Reasoning"
        case .responding: return "Writing response"
        case let .runningTool(toolName, detail): return toolProcessingMessage(forToolName: toolName, detail: detail)
        case .awaitingModel: return "Working"
        case let .applyingConfigurationChange(summary): return "Changing \(summary)"
        }
    }

    private func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Working"
        case .tool:
            if entry.text.localizedCaseInsensitiveContains("waiting for user input") { return nil }
            return toolProcessingMessage(for: entry)
        case .status:
            return statusProcessingMessage(for: entry)
        case .user:
            switch entry.title {
            case "Steering": return "Applying your steering"
            case "Queued follow-up": return "Queued follow-up"
            default: return "Processing your message"
            }
        case .thinking:
            return "Reasoning"
        case .raw:
            return "Working"
        }
    }

    private func statusProcessingMessage(for entry: PiAgentTranscriptEntry) -> String? {
        // Soft system-notice cards (notify / setStatus / setWidget / compaction)
        // are terminal chrome, not an in-flight turn — never keep the processing bar.
        if entry.isSystemNoticeStatus { return nil }
        switch entry.title {
        case "Input Sent": return "Processing your response"
        case "Input Needed": return nil
        case "Retry": return "Retrying request"
        case "Compaction": return "Compacting context"
        case "Deck Agent Requested": return "Starting Deck agent"
        case "Parallel Deck Agents Requested": return "Starting parallel run"
        case "Supervisor Response Routed": return "Routing response"
        case "System Prompt Captured": return "Preparing context"
        case "Process Ended", "Stopped": return nil
        case "Notify", "Notify Warning", "Notify Error",
             "Extension Status", "Extension Widget":
            return nil
        default: return "Processing update"
        }
    }

    private func toolProcessingMessage(for entry: PiAgentTranscriptEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("Tool:") else { return "Running tool" }
        let toolName = title.dropFirst("Tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = mcpToolAddress(from: entry.rawJSON)
        return toolProcessingMessage(forToolName: toolName, detail: detail)
    }

    /// Resolves the `server/tool` address from an MCP proxy entry's raw JSON,
    /// so the live status row can say "Running MCP xcode/ListWindows" instead of
    /// the generic "Running mcp".
    private func mcpToolAddress(from rawJSON: String?) -> String? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              let args = event.args,
              let rawTool = args["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTool.isEmpty,
              let address = MCPConnectionManager.resolveAddress(rawTool, serverHint: args["server"]?.stringValue)
        else { return nil }
        return "\(address.server)/\(address.tool)"
    }

    /// Turns a raw Pi tool name (and, when available, its target) into a
    /// human phrase: `edit` + `PiAgentViews.swift` → "Editing PiAgentViews.swift".
    /// Unknown tools fall back to their de-underscored name so a new Pi tool
    /// still reads acceptably without a code change.
    private func toolProcessingMessage(forToolName toolName: String, detail: String? = nil) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        switch name {
        case "bash": return target.map { "Running \($0)" } ?? "Running a command"
        case "read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "edit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "write": return target.map { "Writing \($0)" } ?? "Writing a file"
        case "web_search": return target.map { "Searching the web for \($0)" } ?? "Searching the web"
        case "code_search": return target.map { "Searching the code for \($0)" } ?? "Searching the code"
        case "get_search_content", "fetch_content": return "Fetching a page"
        case "update_session_plan", "set_session_plan": return "Updating the plan"
        case "managed_subagent": return "Starting Deck agent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating Deck agents"
        case "mcp": return target.map { "Running MCP \($0)" } ?? "Running MCP tool"
        case "": return "Running tool"
        default: return "Running \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func runningSubagentsProcessingMessage(for session: PiAgentSessionRecord) -> String? {
        let agentNames = runningSubagentNames(for: session)
        guard !agentNames.isEmpty else { return nil }
        let prefix = agentNames.count == 1 ? "Running agent" : "Running agents"
        return "\(prefix): \(formattedRunningAgentList(agentNames))"
    }

    private func runningSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        var names: [String] = []
        for run in store.subagentRuns(for: session.id) where run.status.isActive {
            if run.mode == .parallel, let children = run.children, !children.isEmpty {
                names.append(contentsOf: children
                    .filter { $0.status.isActive }
                    .sorted { $0.index < $1.index }
                    .map(\.agentName))
            } else if let child = run.child, child.status.isActive {
                names.append(child.agentName)
            } else {
                names.append(run.agentName)
            }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func formattedRunningAgentList(_ names: [String]) -> String {
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        guard uniqueNames.count > 3 else { return uniqueNames.joined(separator: ", ") }
        return uniqueNames.prefix(3).joined(separator: ", ") + " +\(uniqueNames.count - 3) more"
    }

    private func scheduleTranscriptCacheUpdate() {
        guard let session = store.selectedSession else {
            transcriptCache.scheduleUpdate(sessionID: nil, revision: 0, rawEntries: [])
            return
        }

        // Hydrate the selected transcript before updating the render cache. Small
        // transcripts decode synchronously here (instant, no spinner); large ones are
        // handed to the background loader and return an empty snapshot so the
        // "Loading transcript" card shows instead of hitching the main thread.
        let entries = store.transcriptForCacheUpdate(session.id)
        transcriptCache.scheduleUpdate(
            sessionID: session.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: entries
        )
    }

    private func requestSelectedTranscriptLoadAfterViewUpdate(for sessionID: UUID?) {
        Task { @MainActor in
            await Task.yield()
            // A newer selection may have arrived while this view update settled.
            // Never hydrate or publish for an obsolete session.
            guard store.selectedSession?.id == sessionID else { return }
            store.requestSelectedTranscriptLoad()
            scheduleTranscriptCacheUpdate()
            viewModel.rehydratePiAgentTranscriptIfNeeded(sessionID)
        }
    }

    private func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    private func resetTranscriptAutoScroll() {
        if !transcriptPinnedState.isPinned {
            transcriptPinnedState.isPinned = true
        }
    }

    private func beginTranscriptAutoScrollTurn() {
        resetTranscriptAutoScroll()
    }

    private func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

    @ViewBuilder
    private var composer: some View {
        let isRunning = store.selectedSession?.status.isActive == true
        let isCompacting = store.selectedSession?.isCompacting == true
        let hasSelectedSession = store.selectedSession != nil
        let suggestionTrigger = composerSuggestionTrigger
        let isFileTrigger: Bool = { if case .file = suggestionTrigger { return true }; return false }()
        let isSlashTrigger: Bool = { if case .slash = suggestionTrigger { return true }; return false }()
        let fileItems = ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
        let showsFileSuggestions = !composerSuggestionsDismissed && isFileTrigger && !fileSuggestionResults.isEmpty
        let slashRows = (!composerSuggestionsDismissed && isSlashTrigger) ? cachedSlashRows : []
        let showsSlashSuggestions = !slashRows.isEmpty
        VStack(spacing: 6) {
            if showsFileSuggestions {
                PiAgentCommandSuggestions(
                    items: fileItems,
                    selectedIndex: composerSuggestionIndex,
                    scrollTick: composerSuggestionScrollTick,
                    onSelect: { item in insertComposerSuggestion(item.insertion) },
                    onHover: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil,
                              index != composerSuggestionIndex else { return }
                        composerSuggestionIndex = index
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else if showsSlashSuggestions {
                PiAgentSlashSuggestions(
                    rows: slashRows,
                    highlightedSelectableIndex: slashState.highlightedIndex,
                    scrollTick: slashState.scrollTick,
                    title: slashPanelTitle,
                    onSelect: { row in handleSlashRowSelect(row) },
                    onHoverSelectable: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil,
                              index != slashState.highlightedIndex else { return }
                        slashState.highlightedIndex = index
                    },
                    onBack: slashCanGoBack ? { popSlashScreen() } : nil
                )
#if DEBUG
                .onAppear { SlashDebugLog.panelRender(rows: slashRows, phase: "appear", query: slashQueryString, universe: slashUniverse) }
                .onChange(of: slashRows.count) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "rowsChanged", query: slashQueryString, universe: slashUniverse) }
                .onChange(of: slashQueryString) { _, _ in SlashDebugLog.panelRender(rows: slashRows, phase: "queryChanged", query: slashQueryString, universe: slashUniverse) }
#endif
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            PiAgentComposerBox(
                text: $composerText,
                pasteAttachments: $composerPasteAttachments,
                nextPasteID: $nextComposerPasteID,
                images: $composerImages,
                files: $composerFiles,
                folders: $composerFolders,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting,
                placeholder: languageStore.composerPlaceholder(hasSelectedSession: hasSelectedSession, isCompacting: isCompacting, isRunning: isRunning, isNoProject: store.selectedSession?.isNoProject == true),
                canSend: !isCompacting && store.selectedSession != nil && (!(store.selectedSession?.status.isActive == true) || store.selectedSession.map { store.canEnqueueComposerMessage(for: $0.id) } == true) && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || !slashSelections.isEmpty),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: piAgentNewSessionProjects,
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                slashSelections: slashSelections,
                onRemoveSlashSelection: { item in slashSelections.removeAll { $0.id == item.id } },
                queuedMessages: store.selectedSession.flatMap { store.composerMessageQueueBySessionID[$0.id] } ?? [],
                onWithdrawQueuedMessage: withdrawQueuedComposerMessage,
                onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
                onStop: { viewModel.stopSelectedPiAgentSession() },
                onCreateSession: createSessionFromComposer,
                onCreateSessionForProject: createSessionFromComposer,
                onClear: clearComposerInput,
                suggestionKeyBridge: composerSuggestionKeyBridge
            )
        }
        .animation(.easeOut(duration: 0.12), value: showsFileSuggestions || showsSlashSuggestions)
        .onChange(of: composerText) { oldText, newText in
#if DEBUG
            SlashDebugLog.textChange(oldText: oldText, newText: newText)
#endif
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
            refreshSlashUniverseLifecycle()
            rebuildSlashSuggestionCache()
        }
        .onChange(of: store.selectedSession?.commandInvocations) { _, _ in
            refreshSlashUniverseFromRuntimeIfNeeded()
        }
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else {
            return nil
        }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token: token, range: range)
    }

    private enum ComposerSuggestionTrigger {
        case slash(query: String)
        case file(query: String)
    }

    private var composerSuggestionTrigger: ComposerSuggestionTrigger? {
        guard let active = activeSuggestionToken,
              let first = active.token.first else { return nil }

        switch first {
        case "/":
            guard store.selectedSession?.isNoProject != true else { return nil }
            // Pi only dispatches slash commands/templates when the prompt starts with `/`.
            // Keep file mentions available anywhere, but only suggest/action slash commands
            // when this token is the first non-whitespace content in the composer.
            let prefix = composerText[..<active.range.lowerBound]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .slash(query: String(active.token.dropFirst()).lowercased())
        case "@":
            return .file(query: String(active.token.dropFirst()).lowercased())
        default:
            return nil
        }
    }

    private var composerSuggestionItems: [ComposerSuggestionItem] {
        // Slash mode now uses `PiAgentSlashSuggestions`; this builder is the
        // file-only path. Commands / skills are intentionally empty here.
        ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
    }

    private var slashQueryString: String {
        if case .slash(let query) = composerSuggestionTrigger { return query }
        return ""
    }

    private var slashSuggestionRows: [SlashSuggestionRow] {
        cachedSlashRows
    }

    private var slashSelectableCount: Int {
        cachedSlashSelectableRows.count
    }

    private var slashPanelTitle: String? {
        switch slashState.screen {
        case .categoryPicker:
            return slashQueryString.isEmpty ? nil : "Search · \(slashQueryString)"
        case .category(let kind):
            switch kind {
            case .command: return "Commands"
            case .prompt: return "Prompts"
            case .skill: return "Skills"
            case .loop: return "Loops"
            }
        }
    }

    private var slashCanGoBack: Bool {
        if case .category = slashState.screen { return true }
        return false
    }

    private var hasFileSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        if case .file = composerSuggestionTrigger { return !fileSuggestionResults.isEmpty }
        return false
    }

    private var hasSlashSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        guard case .slash = composerSuggestionTrigger else { return false }
        return !cachedSlashRows.isEmpty
    }

    private var hasComposerSuggestions: Bool {
        hasFileSuggestions || hasSlashSuggestions
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                if hasSlashSuggestions {
                    let count = slashSelectableCount
                    guard count > 0 else { return }
                    slashState.highlightedIndex = min(max(slashState.highlightedIndex + delta, 0), count - 1)
                    slashState.scrollTick &+= 1
                } else {
                    let count = composerSuggestionItems.count
                    guard count > 0 else { return }
                    composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                    composerSuggestionScrollTick += 1
                }
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: {
                if slashCanGoBack {
                    popSlashScreen()
                } else {
                    composerSuggestionsDismissed = true
                }
            }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        if hasSlashSuggestions {
            guard cachedSlashSelectableRows.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(cachedSlashSelectableRows[slashState.highlightedIndex])
            return true
        }
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
    }

    private func handleSlashRowSelect(_ row: SlashSuggestionRow) {
        switch row.kind {
        case .header:
            return
        case .category(let kind):
            slashState.screen = .category(kind)
            slashState.highlightedIndex = 0
            slashState.scrollTick &+= 1
            rebuildSlashSuggestionCache()
        case .item(let itemRow):
            guard let item = slashUniverse.item(withID: itemRow.itemID) else { return }
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
        rebuildSlashSuggestionCache()
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        let currentItem = viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)

        switch currentItem.payload {
        case .loopCreateNew:
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("agent.loopUnavailable"), text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = LoopDraft()
            loopLaunchDefinition = nil
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        case .loopDefinition(let definition):
            guard store.selectedSession?.projectPathForProjectFeatures != nil else {
                if let sessionID = store.selectedSession?.id {
                    store.append(.init(sessionID: sessionID, role: .error, title: LanguageStore.shared.t("agent.loopUnavailable"), text: "Loops are not available for General Chat sessions."))
                }
                slashSelections = []
                slashState = SlashSuggestionState()
                slashUniverse = .empty
                composerSuggestionsDismissed = true
                return
            }
            loopLaunchDraft = definition.makeDraft()
            loopLaunchDefinition = definition
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            composerSuggestionsDismissed = true
            isLoopLaunchSheetPresented = true
            return
        default:
            break
        }

        // Commands: no chip. Seed editable `/name ` into the composer so the
        // user can append args (e.g. `status`) then send manually.
        if case .command(let slashName, _) = currentItem.payload {
            let existing = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer a single trailing space so typing continues as args.
            if existing.isEmpty {
                composerText = slashName.hasSuffix(" ") ? slashName : "\(slashName) "
            } else if existing.hasPrefix(slashName) {
                // Already has the command; keep whatever the user typed after it.
                composerText = existing.hasSuffix(" ") ? existing : "\(existing) "
            } else {
                // Leftover text becomes args after the chosen command.
                composerText = "\(slashName) \(existing)"
            }
            slashSelections = []
            slashState = SlashSuggestionState()
            slashUniverse = .empty
            slashUniverseRevision &+= 1
            composerSuggestionsDismissed = true
            clearSlashSuggestionCache()
            return
        }

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Skills leave the editor alone — any text the user
        // types becomes the message body.
        if case .prompt(_, let body, _, _) = currentItem.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelections = SlashItem.selections(afterAdding: currentItem, to: slashSelections)
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    private func rebuildSlashSuggestionCache(force: Bool = false) {
        guard !composerSuggestionsDismissed, case .slash = composerSuggestionTrigger else {
            clearSlashSuggestionCache()
            return
        }
        let key = SlashSuggestionRowsCacheKey(
            universeRevision: slashUniverseRevision,
            screen: slashState.screen,
            query: slashQueryString
        )
        guard force || slashRowsCacheKey != key else { return }

        let rows = SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
        cachedSlashRows = rows
        cachedSlashSelectableRows = SlashSuggestionRowBuilder.selectableRows(rows)
        slashRowsCacheKey = key

        if cachedSlashSelectableRows.isEmpty {
            slashState.highlightedIndex = 0
        } else if slashState.highlightedIndex >= cachedSlashSelectableRows.count {
            slashState.highlightedIndex = cachedSlashSelectableRows.count - 1
        }
    }

    private func clearSlashSuggestionCache() {
        cachedSlashRows = []
        cachedSlashSelectableRows = []
        slashRowsCacheKey = nil
    }

    private func resetSlashComposerState() {
        slashSelections = []
        slashUniverse = .empty
        slashUniverseRevision &+= 1
        slashState = SlashSuggestionState()
        clearSlashSuggestionCache()
        lastSlashTriggerActive = false
        composerSuggestionsDismissed = false
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            rebuildSlashUniverseSnapshot(reason: "enter")
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
#if DEBUG
            SlashDebugLog.write("slash.lifecycle.exit", slashUniverse.debugLogFields(rowCount: slashSuggestionRows.count))
#endif
            slashUniverse = .empty
            slashUniverseRevision &+= 1
            slashState = SlashSuggestionState()
            clearSlashSuggestionCache()
        }
        lastSlashTriggerActive = isSlashActive
    }

    /// Rebuild `/` catalog while the panel is open (e.g. after `get_commands`).
    private func refreshSlashUniverseFromRuntimeIfNeeded() {
        guard case .slash = composerSuggestionTrigger else { return }
        rebuildSlashUniverseSnapshot(reason: "runtime")
        rebuildSlashSuggestionCache()
    }

    private func rebuildSlashUniverseSnapshot(reason: String) {
        let projectPath: String?
        let useSelectedProjectFallback: Bool
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
            useSelectedProjectFallback = false
        } else {
            projectPath = viewModel.selectedProjectPath
            useSelectedProjectFallback = true
        }
#if DEBUG
        SlashDebugLog.write("slash.lifecycle.\(reason)", [
            "query": slashQueryString,
            "projectPath": projectPath,
            "runtimeCount": store.selectedSession?.runtimeSlashCommands?.count ?? 0
        ])
        SlashDebugLog.write("slash.universe.build.start", ["projectPath": projectPath, "reason": reason])
        let buildStart = Date()
#endif
        slashUniverse = viewModel.slashUniverse(
            forProjectPath: projectPath,
            useSelectedProjectFallback: useSelectedProjectFallback,
            runtimeSlashCommands: store.selectedSession?.runtimeSlashCommands
        )
        slashUniverseRevision &+= 1
#if DEBUG
        let durationMS = Date().timeIntervalSince(buildStart) * 1000
        SlashDebugLog.write("slash.universe.build.end", slashUniverse.debugLogFields(durationMS: durationMS))
#endif
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = runtimeCommandInvocations(excludingSkills: true) ?? fallbackCommandInvocations
        return all.filter { query.isEmpty || $0.dropFirst().lowercased().hasPrefix(query) }.prefix(8).map { $0 }
    }

    private var skillSlashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        let normalizedQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
        let all = runtimeCommandInvocations(onlySkills: true) ?? fallbackSkillInvocations
        return all
            .filter { invocation in
                let name = invocation.replacingOccurrences(of: "/skill:", with: "")
                return normalizedQuery.isEmpty || name.lowercased().hasPrefix(normalizedQuery)
            }
            .prefix(8)
            .map { $0 }
    }

    private func runtimeCommandInvocations(onlySkills: Bool = false, excludingSkills: Bool = false) -> [String]? {
        guard let commands = store.selectedSession?.commandInvocations else { return nil }
        let filtered = commands.filter { invocation in
            let isSkill = invocation.hasPrefix("/skill:")
            if onlySkills { return isSkill }
            if excludingSkills { return !isSkill }
            return true
        }
        return Array(Set(filtered)).sorted()
    }

    private var fallbackCommandInvocations: [String] {
        let configuredCommands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: viewModel.appSettings) }
            .map(\.slashName)
        return Array(Set(snapshotForSelectedSession.promptTemplates.map(\.invocation) + configuredCommands + ["/compact"]))
            .sorted()
    }

    private var fallbackSkillInvocations: [String] {
        // Runtime RPC is authoritative. Before it responds, use active skills only;
        // External/catalog-only skills are management records, not guaranteed runtime commands.
        var seen = Set<String>()
        return snapshotForSelectedSession.skills
            .filter { seen.insert($0.name).inserted }
            .map { "/skill:\($0.name)" }
            .sorted()
    }

    private var snapshotForSelectedSession: ScanSnapshot {
        let projectPath: String?
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
        } else {
            projectPath = viewModel.selectedProjectPath
        }
        return projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
    }

    private var visibleSkillsForSelectedSession: [SkillRecord] {
        let projectPath: String?
        if let session = store.selectedSession {
            projectPath = session.projectPathForProjectFeatures
        } else {
            projectPath = viewModel.selectedProjectPath
        }
        let snapshot = projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
        var seen = Set<String>()
        return (snapshot.skills + snapshot.librarySkills)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Agents offered in the user-message Fork submenu. Returns `nil` (single
    /// fork action) when the session has no subagents enabled, isn't a normal
    /// project session, or no agents are discovered. Re-evaluated when the
    /// selected session, its subagent toggle, or the agent catalog change.
    private var forkAgentChoicesForSelectedSession: [EffectiveAgentRecord]? {
        guard let session = store.selectedSession,
              session.kind != .agent,
              session.subagentsEnabled,
              let projectPath = session.projectPathForProjectFeatures else { return nil }
        let agents = viewModel.selectableAgentUniverse(forProjectPath: projectPath)
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return agents.isEmpty ? nil : agents
    }

    private var fileSuggestions: [PiAgentFileSuggestion] {
        guard case .file = composerSuggestionTrigger else { return [] }
        return fileSuggestionResults
    }

    /// Re-scans `@`-file suggestions off the main thread, debounced. Called only
    /// when the composer text changes — never on hover or arrow-key navigation —
    /// so the filesystem walk never blocks typing or moving the highlight.
    private func refreshFileSuggestions() {
        fileScanTask?.cancel()
        guard let session = store.selectedSession,
              case let .file(query) = composerSuggestionTrigger else {
            fileScanTask = nil
            if !fileSuggestionResults.isEmpty { fileSuggestionResults = [] }
            return
        }
        let rootPath = session.launchWorkingDirectory.path
        fileScanTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                PiAgentFileSuggestion.scan(rootPath: rootPath, query: query)
            }.value
            guard !Task.isCancelled else { return }
            fileSuggestionResults = results
        }
    }

    private func insertComposerSuggestion(_ text: String) {
        replaceCurrentSuggestionToken(with: text)
    }

    private var nativeSubagentRunsByID: [UUID: PiSubagentRunRecord] {
        guard let session = store.selectedSession else { return [:] }
        return Dictionary(uniqueKeysWithValues: store.subagentRuns(for: session.id).map { ($0.id, $0) })
    }

    private func nativeSubagentCard(for run: PiSubagentRunRecord) -> PiNativeSubagentRunCard {
        PiNativeSubagentRunCard(
            run: run,
            onStop: { viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
            onOpenTranscript: { selectedSubagentTranscriptRunID = run.id },
            onReveal: { revealSubagentRun(run) },
            onOpenGraph: { selectedSubagentGraphRunID = run.id },
            onOpenChildTranscript: { selectedSubagentTranscriptRunID = $0 },
            onStopChild: { viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) },
            imageStore: viewModel.agentImageStore
        )
    }

    private var selectedSubagentTranscriptBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentTranscriptRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentTranscriptRunID = newValue?.id }
        )
    }

    private var selectedSubagentGraphBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentGraphRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentGraphRunID = newValue?.id }
        )
    }

    private func revealSubagentRun(_ run: PiSubagentRunRecord) {
        let target = run.outputPath ?? run.artifactDirectory
        guard !target.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    private func replaceCurrentSuggestionToken(with replacement: String) {
        guard let active = activeSuggestionToken else { return }
        composerText.replaceSubrange(active.range, with: replacement)
        composerText += " "
    }

    private func addFileAttachments(_ urls: [URL]) {
        let attachments = urls.filter { !$0.hasDirectoryPath }.compactMap { PiAgentFileAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        // O(1) membership instead of `contains(where:)` per attachment; the Set
        // also de-dupes within the incoming batch.
        var seenURLs = Set(composerFiles.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        var seenURLs = Set(composerFolders.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFolders.append(attachment)
        }
    }

    private func loadComposerDraft(for sessionID: UUID?) {
        resetComposerHistoryNavigation()
        if let pending = viewModel.consumePendingPiAgentComposerText() {
            composerText = pending
            composerPasteAttachments = []
            nextComposerPasteID = 1
            composerImages = []
            composerFiles = []
            composerFolders = []
            composerAttachmentError = nil
            saveComposerDraft(for: sessionID)
            return
        }

        guard let sessionID else {
            clearComposerInput()
            return
        }
        let draft = store.composerDraft(for: sessionID)
        composerText = draft.text
        composerPasteAttachments = draft.pasteAttachments
        nextComposerPasteID = (draft.pasteAttachments.map(\.id).max() ?? 0) + 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        store.saveComposerDraft(text: composerText, pasteAttachments: composerPasteAttachments, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
    }

    private func clearComposerInput() {
        resetComposerHistoryNavigation()
        composerText = ""
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = []
        composerFiles = []
        composerFolders = []
        composerAttachmentError = nil
        slashSelections = []
        slashState = SlashSuggestionState()
    }

    private func resetComposerHistoryNavigation(keepDraft: Bool = false) {
        composerHistoryIndex = nil
        if !keepDraft {
            composerHistoryDraft = ""
        }
    }

    private func createSessionFromComposer() {
        createSessionFromComposer(for: nil)
    }

    private func createSessionFromComposer(for project: DiscoveredProject?) {
        guard store.selectedSession == nil else { return }
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty
        if let project {
            viewModel.createPiAgentDraft(for: project)
        } else {
            viewModel.createPiAgentDraftForSelectedProject()
        }
        if shouldSend {
            sendComposerMessage()
        }
    }


    private func sendComposerMessage() {
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
        let baseMessage = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTranscript = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSlashSelections = slashSelections.map { item in
            if case .prompt = item.payload { return item }
            return viewModel.refreshedSlashItemForUse(item, projectPath: store.selectedSession?.projectPathForProjectFeatures)
        }
        let message = SlashItem.materialize(selections: currentSlashSelections, userText: baseMessage)
        let transcriptMessage = SlashItem.materialize(selections: currentSlashSelections, userText: baseTranscript)
        let titleSource = SlashItem.titleGenerationSource(selections: currentSlashSelections, userText: baseTranscript)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        // While a turn is active, queue follow-ups (no immediate steer / no transcript yet).
        if isRunning, let sessionID = sentSessionID {
            guard store.canEnqueueComposerMessage(for: sessionID) else {
                composerAttachmentError = LanguageStore.shared.t(
                    "composer.queue.full",
                    PiAgentSessionStore.maxComposerMessageQueueCount
                )
                return
            }
            let item = PiAgentQueuedComposerMessage(
                message: combined,
                transcriptText: transcriptCombined,
                composerText: composerText,
                titleSource: titleSource,
                images: composerImages,
                pasteAttachments: activePasteAttachments,
                files: composerFiles,
                folders: composerFolders,
                slashSelectionIDs: currentSlashSelections.map(\.id)
            )
            guard store.enqueueComposerMessage(item, for: sessionID) != nil else {
                composerAttachmentError = LanguageStore.shared.t(
                    "composer.queue.full",
                    PiAgentSessionStore.maxComposerMessageQueueCount
                )
                return
            }
            composerAttachmentError = nil
            clearComposerInput()
            store.clearComposerDraft(for: sessionID)
            return
        }
        let accepted = viewModel.sendPiAgentMessage(combined, mode: .prompt, transcriptText: transcriptCombined, titleSource: titleSource, images: composerImages, pasteAttachments: activePasteAttachments, beforeStart: beginTranscriptAutoScrollTurn)
        guard accepted else { return }
        requestTranscriptBottomScroll()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    /// Moves a queued follow-up back into the composer so the user can edit or drop it.
    private func withdrawQueuedComposerMessage(_ item: PiAgentQueuedComposerMessage) {
        guard let sessionID = store.selectedSession?.id else { return }
        guard let withdrawn = store.withdrawComposerMessage(id: item.id, for: sessionID) else { return }
        composerText = withdrawn.composerText
        composerPasteAttachments = withdrawn.pasteAttachments
        nextComposerPasteID = max(nextComposerPasteID, (withdrawn.pasteAttachments.map(\.id).max() ?? 0) + 1)
        composerImages = withdrawn.images
        composerFiles = withdrawn.files
        composerFolders = withdrawn.folders
        composerAttachmentError = nil
        slashSelections = []
        slashState = SlashSuggestionState()
        saveComposerDraft(for: sessionID)
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = session.launchWorkingDirectory
        return message
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                guard part.hasPrefix("@"), part.count > 1 else { return String(part) }
                let relative = String(part.dropFirst())
                let url = rootURL.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { return String(part) }
                return fileTag(for: url)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles {
            tags.append(fileTag(for: file.url))
        }
        for folder in composerFolders {
            tags.append(folderReference(for: folder.url))
        }
        return tags.joined(separator: "\n")
    }

    private func folderReference(for url: URL) -> String {
        "folder: `\(url.path)`"
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
    }

    private var runningCount: Int {
        scopedSessions.count(where: { viewModel.piAgentSessionIsWorking($0) })
    }

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return LanguageStore.shared.t("session.emptyForProject", project.name)
        }
        return LanguageStore.shared.t("session.emptyHint")
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
    }

    private func syncVisibleSessionSelection() {
        // Selection validity is owned by ONE canonical rule on the view model
        // (project scope only — never this panel's search/attention filters).
        // See the sidebar panel's twin for the ping-pong this replaces.
        viewModel.reconcileSelectedSessionWithProjectScope()
    }

    private func syncMultiSelectionToSelectedSession() {
        // Only write @State when it actually changes — an unconditional assign
        // re-evaluates the whole screen body (and re-runs the transcript's
        // updateNSView) on every sidebar refresh, including streaming pulses.
        guard let selectedID = store.selectedSession?.id else {
            if !selectedSessionIDs.isEmpty { selectedSessionIDs = [] }
            lastSelectedSessionID = nil
            return
        }
        // A list click has already written the (possibly multi) selection —
        // collapsing to a single here was what killed ⌘/⇧ multi-select. Only
        // reset when the current session jumped OUTSIDE the set.
        if !selectedSessionIDs.contains(selectedID) {
            selectedSessionIDs = [selectedID]
        }
        lastSelectedSessionID = selectedID
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        var next = selectedSessionIDs.intersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) {
            next.insert(selectedID)
        }
        // Guard the @State write so a session-list reorder (e.g. streaming bumping
        // a session's activity) doesn't pulse selection and storm the body.
        if next != selectedSessionIDs { selectedSessionIDs = next }
        if let lastSelectedSessionID, !visibleIDs.contains(lastSelectedSessionID) {
            self.lastSelectedSessionID = store.selectedSession?.id
        }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedSessionIDs.formUnion(visibleSessionIDs[range])
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id), selectedSessionIDs.count > 1 {
                selectedSessionIDs.remove(session.id)
                // Hand the store a session that's still selected — re-selecting
                // the one just deselected would make the sync re-add it.
                let fallbackID = selectedSessionIDs.first
                lastSelectedSessionID = fallbackID
                if let fallbackID { viewModel.selectPiAgentSession(fallbackID) }
                return
            }
            selectedSessionIDs.insert(session.id)
        }
        lastSelectedSessionID = session.id
        viewModel.selectPiAgentSession(session.id)
    }

    private func requestDeleteSessions(_ ids: Set<UUID>, isClearAll: Bool = false) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        pendingDeleteSessionIDs = deleteIDs
        pendingDeleteIsClearAll = isClearAll
        pendingDeleteClearAllProjects = isClearAll && viewModel.selectedProjectPath == nil
        pendingDeleteProjectName = isClearAll && viewModel.selectedProjectPath != nil ? (viewModel.selectedDiscoveredProject?.name ?? "the current project") : nil
        isDeleteSessionsAlertPresented = true
    }

    private func resetPendingSessionDelete() {
        pendingDeleteSessionIDs = []
        pendingDeleteIsClearAll = false
        pendingDeleteClearAllProjects = false
        pendingDeleteProjectName = nil
    }

    private func deleteSessionsImmediately(_ ids: Set<UUID>) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        // Compute the next session to make current before deleting, in the
        // order the user actually sees (the row below the deleted set; the row
        // above if it ran to the end). `nil` when the current selection survives.
        let nextID = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: visibleSessions,
            deletedIDs: deleteIDs,
            selectedID: store.selectedSession?.id
        )
        selectedSessionIDs.subtract(deleteIDs)
        withAnimation(.snappy(duration: 0.18)) {
            // Optimistically drop deleted rows from the rendered sections so the
            // removal animates; `rebuildVisibleSessions()` below recomputes
            // `hiddenCount` and everything else correctly in the same tick.
            cachedSections = cachedSections.map { section in
                let remaining = section.items.filter { !deleteIDs.contains($0.id) }
                let removedInThisSection = section.items.count - remaining.count
                return PiAgentSessionListSection(
                    id: section.id,
                    title: section.title,
                    subtitle: section.subtitle,
                    iconFileURL: section.iconFileURL,
                    fallbackSymbolName: section.fallbackSymbolName,
                    assetName: section.assetName,
                    items: remaining,
                    hiddenCount: section.hiddenCount,
                    isShowMoreActive: section.isShowMoreActive,
                    isCollapsed: section.isCollapsed,
                    totalCount: max(0, section.totalCount - removedInThisSection),
                    isProjectGroup: section.isProjectGroup
                )
            }
            hasBuiltVisibleSessions = true
        }
        viewModel.deletePiAgentSessions(deleteIDs, fallbackSelectionID: nextID)
        rebuildVisibleSessions()
        syncMultiSelectionToSelectedSession()
        syncRuntimeFooterSnapshot()
    }

    private func deletePendingSessions() {
        let ids = pendingDeleteSessionIDs
        resetPendingSessionDelete()
        deleteSessionsImmediately(ids)
    }

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }

    private func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.lastSummary ?? ""
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        session.status.rawValue
    }

    private func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }

    private func sessionKindTagColor(_ kind: PiAgentSessionKind) -> Color {
        switch kind {
        case .issue: return .secondary // historical issue-backed sessions only
        case .agent: return .teal
        case .project, .changesReview: return .blue
        }
    }
}


