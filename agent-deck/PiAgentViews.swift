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
    @ObservedObject var languageStore = LanguageStore.shared
    @Binding var sessionSearchText: String
    var showsSessionsColumn = true
    /// False when this screen is kept mounted but hidden (the user is on another
    /// sidebar tab). While inactive the transcript stops rebuilding its rows on
    /// streaming pulses — see `appKitTranscriptItems`.
    var isActive = true
    @State var composerText = ""
    @State var composerSuggestionIndex = 0
    @State var composerSuggestionsDismissed = false
    @State var composerSuggestionScrollTick = 0
    @State var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State var fileScanTask: Task<Void, Never>?
    /// Cached slash universe. Built once when the `/` panel opens (off the body
    /// hot path, in `.onChange`) and reused for the whole interaction so neither
    /// typing nor scrolling re-walks the catalog.
    @State var slashUniverse: SlashUniverse = .empty
    @State var slashState = SlashSuggestionState()
    @State var slashUniverseRevision = 0
    @State var slashRowsCacheKey: SlashSuggestionRowsCacheKey?
    @State var cachedSlashRows: [SlashSuggestionRow] = []
    @State var cachedSlashSelectableRows: [SlashSuggestionRow] = []
    /// Picked slash items — rendered as glass capsule chips above the editor and
    /// included in the send payload. Only skills/skill collections can stack.
    @State var slashSelections: [SlashItem] = []
    @State var isLoopLaunchSheetPresented = false
    @State var loopLaunchDraft = LoopDraft()
    @State var loopLaunchDefinition: LoopDefinition?
    @State var lastSlashTriggerActive = false
    @State var inputMode: PiAgentInputMode = .steer
    @State var selectedSessionIDs: Set<UUID> = []
    @State var lastSelectedSessionID: UUID?
    @State var pendingDeleteSessionIDs: Set<UUID> = []
    @State var pendingDeleteIsClearAll = false
    @State var pendingDeleteClearAllProjects = false
    @State var pendingDeleteProjectName: String?
    @State var isDeleteSessionsAlertPresented = false
    @State var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State var nextComposerPasteID = 1
    @State var composerImages: [PiAgentImageAttachment] = []
    @State var composerFiles: [PiAgentFileAttachment] = []
    @State var composerFolders: [PiAgentFolderAttachment] = []
    @State var composerAttachmentError: String?
    @State var composerHistoryIndex: Int?
    @State var composerHistoryDraft = ""
    @State var selectedSubagentTranscriptRunID: UUID?
    @State var selectedSubagentGraphRunID: UUID?
    // Owned but NOT observed: `@State` (not `@StateObject`) holds the cache for the
    // view's lifetime without subscribing `PiAgentScreen.body` to its
    // `objectWillChange`. The cache pulses `streamingRevision` ~30Hz while a session
    // streams; subscribing the whole screen re-evaluated the session list + composer
    // on every pulse (the SessionListContent re-eval storm). Only the extracted
    // `PiAgentTranscriptHost` child takes the cache as `@ObservedObject`, so the
    // pulse now re-renders the transcript table alone. The cache is driven entirely
    // by `store.*`-keyed `.task`/`.onChange` triggers, which the parent still
    // observes — so dropping the subscription doesn't miss any update.
    @State var transcriptCache = PiAgentTranscriptRenderCache()
    @State var transcriptBottomScrollRequest = 0
    // Pinned-to-bottom lives in its own ObservableObject, held by `@State` so this
    // screen's body watches only the reference identity — NOT `isPinned`. Scrolling
    // flips `isPinned` ~constantly; if the screen body read it directly, every flip
    // would re-evaluate the whole body and re-run the O(N) `appKitTranscriptItems`
    // build (the `itemsBuild` scroll cost). Only `JumpToLatestOverlay` `@ObservedObject`s
    // it, so a flip re-renders just the pill, leaving the transcript host untouched.
    @State var transcriptPinnedState = TranscriptPinnedState()
    @State var showArchivedPreCompactionTranscript = false
    @State var isEarlierTranscriptSheetPresented = false
    @State var cachedSections: [PiAgentSessionListSection] = []
    @State var hasBuiltVisibleSessions = false
    @State var sessionScrollRequest: UUID?
    /// Per-session derived git activity (commit/push/merge timestamps), keyed by
    /// session.id. Rebuilt off the body hot path on transcript-revision or
    /// visible-set changes — never recomputed inline in row `body` to avoid
    /// jank (see `[[feedback_performance_sensitive]]`).
    @State var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State var isUIRequestSheetPresented = false
    @State var isSupervisorRequestSheetPresented = false
#if DEBUG
    @State var didStartPickerStress = false
    @State var pickerStressExpansionRequest = false
    @State var pickerStressRowSource: PickerStressRowSource = .synthetic
    @State var pickerStressAcknowledgements = PickerStressCardAcknowledgements()
#endif
    @State var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State var stabilizedProcessingMessage: String?
    @State var processingMessageUpdateTask: Task<Void, Never>?
    // True while a Review/sidebar splitter drag is active. Suppresses the
    // transcript edge-fade `.mask` (which smears into a blur mask over the
    // middle column mid-drag) until the drag ends and the table re-lays out.
    @State var isColumnResizing = false

    // Keep long sessions cheap to relayout when side panels open; older visible items remain accessible separately.
    let recentTranscriptTimelineItemLimit = 50

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
}
