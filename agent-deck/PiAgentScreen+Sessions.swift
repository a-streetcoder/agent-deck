import AppKit
import Combine
import SwiftUI

// MARK: - Session list, selection, delete, picker stress

extension PiAgentScreen {
    func handleSelectedTranscriptRevisionTask() async {
        await Task.yield()
        scheduleTranscriptCacheUpdate()
    }

    var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var scopedSessions: [PiAgentSessionRecord] {
        store.sessions
    }

    var isAllProjects: Bool { true }

    var visibleSections: [PiAgentSessionListSection] {
        hasBuiltVisibleSessions ? cachedSections : computedSections()
    }

    /// Flattened rendered sessions (preview sets only) for helpers that still
    /// think in terms of a flat list — selection sync, working set, activity
    /// cache. Hidden sessions are intentionally excluded.
    var visibleSessions: [PiAgentSessionRecord] { visibleSections.flatMap(\.items) }

    func rebuildVisibleSessions() {
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

    func computedSections() -> [PiAgentSessionListSection] {
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

    var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    func rebuildSessionActivityCache() {
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

    var deleteSessionsAlertTitle: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects { return LanguageStore.shared.t("session.clearAllTitle") }
            let projectName = pendingDeleteProjectName ?? LanguageStore.shared.t("session.thisProject")
            return LanguageStore.shared.t("session.clearProjectTitle", projectName)
        }
        return pendingDeleteSessionIDs.count == 1
            ? LanguageStore.shared.t("session.deleteTitle")
            : LanguageStore.shared.t("session.deleteTitleMany", pendingDeleteSessionIDs.count)
    }

    var deleteSessionsAlertMessage: String {
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

    var sessionDeleteTargets: Set<UUID> {
        if !selectedSessionIDs.isEmpty {
            return selectedSessionIDs
        }
        if let selectedID = store.selectedSession?.id {
            return [selectedID]
        }
        return []
    }

    var uiRequestSheetBinding: Binding<Bool> {
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

    var supervisorRequestSheetBinding: Binding<Bool> {
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

    var selectedPendingSupervisorRequest: PiSubagentSupervisorRequest? {
        guard let sessionID = store.selectedSession?.id else { return nil }
        return store.supervisorRequests(for: sessionID)
            .filter { $0.status == .pending && $0.kind.isBlocking }
            .sorted { lhs, rhs in lhs.createdAt < rhs.createdAt }
            .first
    }


    var sessionsColumn: some View {
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
    var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    var uiRequestVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

#if DEBUG
    var isPickerStressRequested: Bool {
        ProcessInfo.processInfo.environment["AGENTDECK_PICKER_STRESS"] != nil
    }

    @MainActor
    func runPickerStressIfRequested() async {
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

    func pickerStressProjectFromEnvironment() -> DiscoveredProject? {
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

    func waitForPickerStressCard(
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

    func pickerStressCatalogHeightIsApproximately(_ expected: CGFloat) -> Bool {
        abs(pickerStressAcknowledgements.catalogSize.height - expected) <= 2
    }

    func pickerStressSizeDescription(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    func pickerStressLog(_ line: String) {
        fputs(line + "\n", stderr)
        TranscriptScrollProfiler.fileLog(line)
    }
#endif

    var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        var map: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions where sessionActivityCache[session.id] != nil {
            map[session.id] = sessionActivityCache[session.id]
        }
        return map
    }

    var activeLoopSessionIDs: Set<UUID> {
        activeLoopSessionIDs(in: visibleSessions)
    }

    func activeLoopSessionIDs(in sessions: [PiAgentSessionRecord]) -> Set<UUID> {
        let sessionIDs = Set(sessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            sessionIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }

    // The active column's dynamic cards must not feed transient intrinsic minima
    // back into the enclosing split-view child during a resize pass.

    func syncVisibleSessionSelection() {
        // Selection validity is owned by ONE canonical rule on the view model
        // (project scope only — never this panel's search/attention filters).
        // See the sidebar panel's twin for the ping-pong this replaces.
        viewModel.reconcileSelectedSessionWithProjectScope()
    }

    func syncMultiSelectionToSelectedSession() {
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

    func pruneMultiSelectionToVisibleSessions() {
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

    func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
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

    func requestDeleteSessions(_ ids: Set<UUID>, isClearAll: Bool = false) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        pendingDeleteSessionIDs = deleteIDs
        pendingDeleteIsClearAll = isClearAll
        pendingDeleteClearAllProjects = isClearAll && viewModel.selectedProjectPath == nil
        pendingDeleteProjectName = isClearAll && viewModel.selectedProjectPath != nil ? (viewModel.selectedDiscoveredProject?.name ?? "the current project") : nil
        isDeleteSessionsAlertPresented = true
    }

    func resetPendingSessionDelete() {
        pendingDeleteSessionIDs = []
        pendingDeleteIsClearAll = false
        pendingDeleteClearAllProjects = false
        pendingDeleteProjectName = nil
    }

    func deleteSessionsImmediately(_ ids: Set<UUID>) {
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

    func deletePendingSessions() {
        let ids = pendingDeleteSessionIDs
        resetPendingSessionDelete()
        deleteSessionsImmediately(ids)
    }

    func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }

    func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.lastSummary ?? ""
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        session.status.rawValue
    }

    func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }

    func sessionKindTagColor(_ kind: PiAgentSessionKind) -> Color {
        switch kind {
        case .issue: return .secondary // historical issue-backed sessions only
        case .agent: return .teal
        case .project, .changesReview: return .blue
        }
    }
}
