import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentComposerPanel: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @ObservedObject private var languageStore = LanguageStore.shared
    /// Value snapshot used both for draft ownership and the Equatable boundary.
    /// The store reference is stable across selections, so identity alone cannot
    /// tell SwiftUI that the composer must save one session and restore another.
    let selectedSessionID: UUID?
    let onWillSend: () -> Void
    let onDidSend: () -> Void

    @State private var composerText = ""
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    @State private var slashUniverse: SlashUniverse = .empty
    @State private var slashState = SlashSuggestionState()
    @State private var slashUniverseRevision = 0
    @State private var slashRowsCacheKey: SlashSuggestionRowsCacheKey?
    @State private var cachedSlashRows: [SlashSuggestionRow] = []
    @State private var cachedSlashSelectableRows: [SlashSuggestionRow] = []
    @State private var slashSelections: [SlashItem] = []
    @State private var isLoopLaunchSheetPresented = false
    @State private var loopLaunchDraft = LoopDraft()
    @State private var loopLaunchDefinition: LoopDefinition?
    @State private var lastSlashTriggerActive = false
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State private var loopDetailsRun: LoopRun?

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let activeLoopRun = store.selectedSession.flatMap { store.activeLoopRun(for: $0.id) }
        let visibleLoopRun = store.selectedSession.flatMap { session in
            activeLoopRun ?? store.loopRuns(for: session.id).last
        }
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
            if activeLoopRun == nil {
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
            }
            if let visibleLoopRun {
                PiAgentLoopControlBar(
                    run: visibleLoopRun,
                    onOpenDetails: { loopDetailsRun = visibleLoopRun },
                    onStop: { _ = store.stopLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID) },
                    onRetry: { viewModel.retryLoopRun(visibleLoopRun) },
                    onSave: saveLoopAction(for: visibleLoopRun),
                    onRevealArtifacts: revealArtifactsAction(for: visibleLoopRun),
                    onRevealWorktree: revealWorktreeAction(for: visibleLoopRun),
                    onApplyWorktree: { viewModel.applyLoopWorktree(visibleLoopRun) },
                    onDiscardWorktree: discardWorktreeAction(for: visibleLoopRun),
                    onApproveHumanApproval: { _ = store.resolveHumanApprovalLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID, approved: true) },
                    onRejectHumanApproval: { _ = store.resolveHumanApprovalLoopRun(visibleLoopRun.id, sessionID: visibleLoopRun.sessionID, approved: false) }
                )
            }
            if activeLoopRun == nil {
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
                    canSend: !isCompacting && store.selectedSession != nil && activeLoopRun == nil && (!(store.selectedSession?.status.isActive == true) || store.selectedSession.map { store.canEnqueueComposerMessage(for: $0.id) } == true) && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || !slashSelections.isEmpty),
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
        }
        .animation(.easeOut(duration: 0.12), value: showsFileSuggestions || showsSlashSuggestions)
        .sheet(item: $loopDetailsRun) { run in
            let canRevealWorktree = canRevealLoopWorktree(run)
            PiAgentLoopDetailsSheet(
                run: run,
                revealActionTitle: canRevealWorktree ? "Reveal Worktree" : "Reveal Artifacts",
                onRevealAction: canRevealWorktree ? revealWorktreeAction(for: run) : revealArtifactsAction(for: run)
            )
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
            // Mirror the draft into the session store on every keystroke so an
            // unsent message survives a window re-key (a theme change rebuilds
            // the view tree). `onAppear` below restores it into the new tree.
            saveComposerDraft(for: selectedSessionID)
        }
        .onChange(of: store.selectedSession?.commandInvocations) { _, _ in
            refreshSlashUniverseFromRuntimeIfNeeded()
        }
        .onAppear {
            syncRuntimeFooterSnapshot()
            loadComposerDraft(for: selectedSessionID)
        }
        .onDisappear {
            saveComposerDraft(for: selectedSessionID)
        }
        .onChange(of: selectedSessionID) { oldID, newID in
            saveComposerDraft(for: oldID)
            loadComposerDraft(for: newID)
            syncRuntimeFooterSnapshot()
            resetSlashComposerState()
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
    }


    private func revealArtifactsAction(for run: LoopRun) -> (() -> Void)? {
        guard let path = run.artifactDirectoryPath else { return nil }
        return { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    private func revealWorktreeAction(for run: LoopRun) -> (() -> Void)? {
        guard let path = run.artifactDirectoryPath else { return nil }
        return {
            NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: path).appendingPathComponent("worktree", isDirectory: true)
            ])
        }
    }

    private func canRevealLoopWorktree(_ run: LoopRun) -> Bool {
        guard run.writeTarget == .newWorktree,
              let path = run.artifactDirectoryPath else { return false }
        let artifactDirectoryURL = URL(fileURLWithPath: path)
        let hasWorktree = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree", isDirectory: true).path)
        let hasAppliedMarker = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.applied").path)
        let hasDiscardedMarker = FileManager.default.fileExists(atPath: artifactDirectoryURL.appendingPathComponent("worktree.discarded").path)
        let worktreeAlreadyHandled = run.worktreeState == .applied || run.worktreeState == .discarded || hasAppliedMarker || hasDiscardedMarker
        return hasWorktree && !worktreeAlreadyHandled
    }

    private func saveLoopAction(for run: LoopRun) -> () -> Void {
        { [viewModel, store] in
            do {
                _ = try viewModel.saveLoopDefinitionFromRun(run)
                store.append(.init(sessionID: run.sessionID, role: .status, title: LanguageStore.shared.t("agent.loopSaved"), text: LanguageStore.shared.t("agent.loopSavedBody")))
            } catch {
                store.append(.init(sessionID: run.sessionID, role: .error, title: LanguageStore.shared.t("agent.loopSaveFailed"), text: error.localizedDescription))
            }
        }
    }

    private func discardWorktreeAction(for run: LoopRun) -> () -> Void {
        { [viewModel] in
            let alert = NSAlert()
            alert.messageText = "Discard loop worktree?"
            alert.informativeText = "This removes the loop worktree. Loop artifacts are kept, but unapplied worktree changes will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard Worktree")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            viewModel.discardLoopWorktree(run)
        }
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else { return nil }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token, range)
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
        // The slash selection is not part of a persisted composer draft. Drop
        // it whenever a draft is loaded (session switch, window re-key, etc.)
        // so a skill chip from session A never leaks into session B.
        slashSelections = []

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
        if let session = store.selectedSession, store.activeLoopRun(for: session.id) != nil {
            store.append(.init(sessionID: session.id, role: .status, title: LanguageStore.shared.t("agent.composerLocked"), text: LanguageStore.shared.t("agent.composerLockedBody")))
            return
        }
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
        let accepted = viewModel.sendPiAgentMessage(combined, mode: .prompt, transcriptText: transcriptCombined, titleSource: titleSource, images: composerImages, pasteAttachments: activePasteAttachments, beforeStart: onWillSend)
        guard accepted else { return }
        onDidSend()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

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
        for file in composerFiles { tags.append(fileTag(for: file.url)) }
        for folder in composerFolders { tags.append(folderReference(for: folder.url)) }
        return tags.joined(separator: "\n")
    }

    private func folderReference(for url: URL) -> String {
        "folder: `\(url.path)`"
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
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

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }
}

// Protect the composer — the app's most expensive chrome (glass card, slash
// menu, suggestions) — from the parent transcript view's per-streaming-token
// body churn. The parent re-runs ~30×/sec while tokens arrive (its body reads
// the transcript cache); without this the composer's body re-ran each time even
// though nothing it shows changed. Most display state is driven by `@Observable`
// reads of the two long-lived stores, but the selected session is also passed as
// an immutable value snapshot. That value must participate in equality so the
// draft save/restore lifecycle runs on a session switch. Ignoring the closures,
// which are recreated every parent pass, still skips streaming churn.
extension PiAgentComposerPanel: Equatable {
    nonisolated static func == (lhs: PiAgentComposerPanel, rhs: PiAgentComposerPanel) -> Bool {
        lhs.viewModel === rhs.viewModel
            && lhs.store === rhs.store
            && lhs.selectedSessionID == rhs.selectedSessionID
    }
}
