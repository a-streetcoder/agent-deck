import AppKit
import Foundation
import UserNotifications

// MARK: - Session create / select / pin / resume

extension AppViewModel {
    func openPiAgentForSelectedProject() {
        selectedSidebarItem = .agent
        let project = piAgentSessionProjectContext()
        if piAgentSessionStore.selectedSession?.projectPath != project.path {
            let existing = piAgentSessionStore.sessions.first { $0.projectPath == project.path && $0.kind == .project }
            if let existing {
                selectPiAgentSession(existing.id)
                ensurePiAgentModelCatalogLoaded()
            } else {
                let session = piAgentSessionStore.createSession(
                    kind: .project,
                    title: LanguageStore.shared.t("vm.projectAgent", project.name),
                    project: project,
                    repository: project.gitHubRemote?.nameWithOwner
                )
                revealSessionGroup(session)
                selectPiAgentSession(session.id)
            }
        } else {
            acknowledgeVisibleSelectedPiAgentSession()
        }
    }

    func createPiAgentDraftForSelectedSessionProjectOrSelectedProject() {
        if let sessionProjectPath = piAgentSessionStore.selectedSession?.projectPathForProjectFeatures,
           let project = projectByPath[sessionProjectPath] {
            createPiAgentDraft(for: project)
            return
        }

        createPiAgentDraftForSelectedProject()
    }

    func createPiAgentDraftForSelectedProject() {
        guard let project = selectedDiscoveredProject else {
            createNoProjectPiAgentDraft()
            return
        }
        createPiAgentDraft(for: project)
    }

    func createNoProjectPiAgentDraft() {
        selectedSidebarItem = .agent
        let session = piAgentSessionStore.createNoProjectCodingAgentSession()
        uncollapseSessionGroup(session)
        selectPiAgentSession(session.id)
    }

    func createAgentDeckBuilderDraft() {
        selectedSidebarItem = .agent
        let session = piAgentSessionStore.createAgentDeckBuilderSession()
        uncollapseSessionGroup(session)
        selectPiAgentSession(session.id)
    }

    func createPiAgentDraft(for project: DiscoveredProject) {
        selectedSidebarItem = .agent
        let session = piAgentSessionStore.createSession(
            kind: .project,
            title: "Draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        // Settle selection synchronously: createSession already inserts, sorts,
        // and assigns `selectedSessionID`; uncollapse the target's group so the
        // new row can render, but do not activate "Show more". New sessions are
        // already in the preview set, and expanding here makes the 5-row
        // "Show less" list unexpectedly become the full list when pressing +.
        // selectPiAgentSession commits the sidebar tab. A second re-assertion on
        // the next runloop was only here to win the fight against the old
        // per-project `selectedProjectPath` reconciler, which is gone now.
        uncollapseSessionGroup(session)
        selectPiAgentSession(session.id)
    }

    func startPiAgentForSelectedProject(initialInstruction: String) {
        guard let project = selectedDiscoveredProject else {
            selectedSidebarItem = .agent
            let title = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "General Chat"
            let session = piAgentSessionStore.createNoProjectCodingAgentSession(
                title: title.isEmpty ? LanguageStore.shared.t("vm.generalChat") : String(title.prefix(80))
            )
            revealSessionGroup(session)
            selectPiAgentSession(session.id)
            piAgentRunner.resume(session: session, initialPrompt: initialInstruction)
            return
        }
        selectedSidebarItem = .agent

        // If worktree isolation is enabled, create the session and provision the
        // worktree before the runner spawns Pi — otherwise Pi launches in the
        // project root and won't pick up the worktree path on the first turn.
        if appSettings.piAgentSessionsUseWorktree, project.isGitRepository {
            let title = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "Project agent · \(project.name)"
            let session = piAgentSessionStore.createSession(
                kind: .project,
                title: title.isEmpty ? LanguageStore.shared.t("vm.newAgentSession") : String(title.prefix(80)),
                project: project,
                repository: project.gitHubRemote?.nameWithOwner
            )
            revealSessionGroup(session)
            selectPiAgentSession(session.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.provisionWorktreeIfEnabled(for: session.id, project: project)
                guard let refreshed = self.piAgentSessionStore.sessions.first(where: { $0.id == session.id }) else { return }
                let prompt = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                self.piAgentRunner.resume(session: refreshed, initialPrompt: prompt)
            }
            return
        }

        piAgentRunner.startProjectSession(project: project, initialInstruction: initialInstruction)
    }



    func consumePendingPiAgentComposerText() -> String? {
        guard let pending = piAgentPendingComposerText else { return nil }
        piAgentPendingComposerText = nil
        return pending
    }


    func openPiAgentScreen() {
        selectedSidebarItem = .agent
        expandCodingAgentPanel()
    }

    /// Expands the Coding Agent sidebar panel without changing the selected
    /// navigation item. Use for the collapsed panel's disclosure/bench path so
    /// the detail view and toolbar stay stable while the panel animates open.
    func expandCodingAgentPanel() {
        isCodingAgentPanelExpanded = true
        if piAgentSessionStore.selectedSession?.id != nil {
            ensurePiAgentModelCatalogLoaded()
        }
        prepareRepoChangesForSelectedPiAgentSession()
        acknowledgeVisibleSelectedPiAgentSession()
    }

    func selectPiAgentSession(_ id: UUID) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == id }) else { return }
        transientFocusedPiAgentSessionID = nil
        if session.needsAttention {
            transientFocusedPiAgentSessionID = id
        }
        piAgentSessionStore.select(id)
        selectedSidebarItem = .agent
        ensurePiAgentModelCatalogLoaded()
        prepareRepoChangesForSelectedPiAgentSession()
        acknowledgePiAgentSession(id)
    }

    /// The ONE authority for "is the selected session still valid". Now that the
    /// session list is global (no per-project filter), validity is simply "the
    /// selected session still exists in the store". It still ignores per-panel
    /// view filters (search text, attention-only) so two mounted panels with
    /// different filters can never fight over the global selection.
    ///
    /// Previously this also coerced selection into the currently-selected
    /// *project* scope (`selectedProjectPath`). That was correct when the list
    /// was project-scoped, but after unscoping it actively broke the app: a user
    /// could click (or send into) a session whose `projectPath` differs from the
    /// project they last picked for new-session context, and the next list
    /// rebuild (fired by the send's `mark(.running)` → `sessionListRevision`
    /// bump) would call back into here and clear/move the selection right out
    /// from under the turn — leaving the composer in a "no session selected"
    /// state even though the message had already gone out. `selectedProjectPath`
    /// now only drives new-session context and is never assumed to equal the
    /// active session's project.
    func reconcileSelectedSessionWithProjectScope() {
        let store = piAgentSessionStore
        if let id = store.selectedSessionID, store.sessions.contains(where: { $0.id == id }) { return }
        if let first = store.sessions.min(by: { PiAgentSessionRecord.sessionListPrecedes($0, $1) }) {
            store.select(first.id)
        } else {
            store.clearSelection()
        }
    }

    /// Repairs a session's transcript from Pi's session file when it becomes the
    /// visible session — on click, on keyboard nav, and on the selection restored
    /// at launch. Cheap and self-guarding (once per session, only when there's
    /// something missing), so it's safe to call from view appear/selection hooks.
    func rehydratePiAgentTranscriptIfNeeded(_ sessionID: UUID?) {
        guard let sessionID,
              let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        piAgentRunner.rehydrateTranscriptFromSessionFileIfNeeded(session)
    }

    /// Sessions for the active project, in the store's stable order (pinned +
    /// recency) — the base order the sidebar shows before any search filter.
    /// Drives next/previous session navigation and the scroll benchmark.
    func scopedPiAgentSessionsInOrder() -> [PiAgentSessionRecord] {
        guard let path = selectedProjectPath else { return piAgentSessionStore.sessions }
        return piAgentSessionStore.sessions.filter { $0.projectPath == path }
    }

    /// Sessions created or touched (`updatedAt` bumped) during the current app
    /// run. Populated by the store's `createSession`/
    /// `touchSession(bumpUpdatedAt: true)` paths; disk-reload paths keep it clean.
    /// The expanded sidebar surfaces these above its top-N preview cap so a
    /// freshly-created or jostled older chat stays reachable.
    var piAgentSessionsTouchedThisRunIDs: Set<UUID> {
        piAgentSessionStore.sessionsTouchedThisRun
    }


    /// Move selection by `offset` within the active panel's visible session
    /// list, in display order. `wrap == true` wraps at both ends (⌘]/⌘[);
    /// `false` stops at the ends (↑/↓). No-op when there are no sessions.
    ///
    /// Navigation operates on the visible rows the active sidebar panel reports
    /// via `piAgentVisibleSessionsForNavigation`. It does NOT auto-expand a
    /// disclosure-collapsed group or activate "Show more" for a capped one — the
    /// target row must already be visible. When no panel has reported in yet
    /// (e.g. before the first rebuild), it falls back to the scoped session
    /// list in stable order so keyboard shortcuts still work at the start of an
    /// app launch.
    ///
    /// Both ⌘]/⌘[ and the in-list ↑/↓ arrows go through here so the two entry
    /// points share one navigation order.
    func selectAdjacentPiAgentSession(offset: Int, wrap: Bool = true) {
        let ordered = piAgentVisibleSessionsForNavigation.isEmpty
            ? scopedPiAgentSessionsInOrder()
            : piAgentVisibleSessionsForNavigation
        guard !ordered.isEmpty else { return }
        let currentID = piAgentSessionStore.selectedSessionID
        let currentIndex = ordered.firstIndex { $0.id == currentID } ?? 0
        let count = ordered.count
        var nextIndex: Int
        if wrap {
            nextIndex = ((currentIndex + offset) % count + count) % count
        } else {
            nextIndex = min(max(currentIndex + offset, 0), count - 1)
        }
        let target = ordered[nextIndex]
        // No auto-reveal: the target row is already visible (it's in `ordered`,
        // which is the panel's visible row set). The previous `revealSessionGroup`
        // call here drove navigation into hidden preview/collapsed rows, which
        // is no longer desired for the expanded/full sidebar UX.
        selectPiAgentSession(target.id)
    }

    /// Every scoped session in grouped display order, ignoring group collapse
    /// and "Show more" caps — the full pre-`exactSort`/visible-rows rework
    /// navigation surface. Retained for the rare fallback (e.g. nil visible
    /// panels at cold start) and any future caller needing the full set, but
    /// `selectAdjacentPiAgentSession` no longer routes through here.
    func orderedAllSessionsForNavigation() -> [PiAgentSessionRecord] {
        PiAgentSessionGrouping.sections(
            from: scopedPiAgentSessionsInOrder(),
            projectByPath: projectByPath,
            projectDiscoveryComplete: hasCompletedInitialProjectDiscovery,
            expandedProjectIDs: [],
            collapsedProjectIDs: [],
            capPreviews: false,
            isWorking: { _ in false },
            selectedSessionID: nil
        ).flatMap(\.items)
    }

    func sessionGroupID(for session: PiAgentSessionRecord) -> String {
        if session.isAgentDeckBuilderSession { return PiAgentSessionGrouping.agentDeckBuilderSectionID }
        if session.isNoProject { return PiAgentSessionGrouping.noProjectSectionID }
        return projectByPath[session.projectPath] != nil || !hasCompletedInitialProjectDiscovery
            ? session.projectPath
            : PiAgentSessionGrouping.otherSectionID
    }

    /// Ensure the group owning `session` is not disclosure-collapsed without
    /// changing its Show more/less state. Used for newly-created sessions, which
    /// are already visible in the capped preview.
    func uncollapseSessionGroup(_ session: PiAgentSessionRecord) {
        collapsedProjects.remove(sessionGroupID(for: session))
    }

    /// Auto-reveal the group owning `session` so it lands on a rendered row:
    /// expand a disclosure-collapsed group and activate "Show more" for a
    /// capped one. State is shared on the view model so every mounted session
    /// list stays consistent. Used by selection paths that intentionally force
    /// a hidden target visible (e.g. notification tap); keyboard navigation no
    /// longer calls this.
    func revealSessionGroup(_ session: PiAgentSessionRecord) {
        let groupID = sessionGroupID(for: session)
        collapsedProjects.remove(groupID)
        expandedProjects.insert(groupID)
    }

    func selectNextPiAgentSession() { selectAdjacentPiAgentSession(offset: 1, wrap: true) }
    func selectPreviousPiAgentSession() { selectAdjacentPiAgentSession(offset: -1, wrap: true) }

    var canNavigatePiAgentSessions: Bool {
        scopedPiAgentSessionsInOrder().count > 1
    }

    func acknowledgeVisibleSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession,
              isPiAgentSessionActuallyVisible(session.id) else { return }
        if session.needsAttention {
            transientFocusedPiAgentSessionID = session.id
        }
        acknowledgePiAgentSession(session.id)
    }

    func releaseTransientFocusedPiAgentSession() {
        transientFocusedPiAgentSessionID = nil
    }

    func piAgentSessionIsWorking(_ session: PiAgentSessionRecord) -> Bool {
        session.status.isActive || piAgentSessionHasActiveSubagent(session.id)
    }

    func piAgentSessionHasActiveSubagent(_ sessionID: UUID) -> Bool {
        piAgentSessionStore.subagentRuns(for: sessionID).contains { $0.status.isActive }
    }



    func setDefaultPiAgentModel(_ model: AvailableModel?) {
        guard writePiRuntimeDefaults(provider: model?.provider, model: model?.model, thinkingLevel: nil) else { return }
        piRuntimeSettingsRevision += 1
    }

    func setDefaultPiAgentThinkingLevel(_ level: String) {
        guard writePiRuntimeDefaults(provider: nil, model: nil, thinkingLevel: level) else { return }
        piRuntimeSettingsRevision += 1
    }

    func acknowledgePiAgentSession(_ id: UUID) {
        pendingPiAgentNotificationTasks[id]?.cancel()
        pendingPiAgentNotificationTasks[id] = nil
        piAgentSessionStore.updateSession(id) { $0.needsAttention = false }
        let identifier = piAgentNotificationIdentifier(for: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func handlePiAgentTurnFinished(_ sessionID: UUID) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        // Deliver the next queued follow-up before attention/notification bookkeeping.
        // Gate on *turn* status only — `piAgentRunner.isRunning` means the warm RPC
        // process is alive between turns, not that a model turn is in flight.
        if !(piAgentSessionStore.sessions.first(where: { $0.id == sessionID })?.status.isActive ?? false) {
            drainComposerMessageQueueIfNeeded(sessionID: sessionID)
        }
        if isPiAgentSessionActuallyVisible(sessionID) {
            acknowledgePiAgentSession(sessionID)
            // Pi may have changed files during the completed turn. Refresh once at
            // the turn boundary so Git toolbar actions don't keep reading a clean
            // cached snapshot until the user changes sessions.
            if shouldShowPiAgentGitActions,
               piAgentSessionStore.selectedSession?.id == sessionID {
                prepareRepoChangesForSelectedPiAgentSession(force: true)
            }
            return
        }

        guard !session.needsAttention else { return }
        piAgentSessionStore.updateSession(sessionID) { record in
            record.status = .idle
            record.needsAttention = true
        }
        schedulePiAgentCompletionNotification(for: sessionID)
    }

    /// Sends at most one queued composer message after a turn becomes idle.
    /// Further items wait for the next `onTurnFinished`.
    ///
    /// Note: do **not** use `piAgentRunner.isRunning` as a turn gate. That flag is true
    /// whenever the warm Pi RPC child process is alive (including between turns).
    func drainComposerMessageQueueIfNeeded(sessionID: UUID) {
        guard let item = piAgentSessionStore.dequeueComposerMessage(for: sessionID) else { return }
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else {
            // Session gone — drop the dequeued item.
            return
        }
        // Re-queue if a new turn started between dequeue and send.
        if ComposerMessageQueue.shouldRequeueAfterDrain(sessionIsActive: session.status.isActive) {
            piAgentSessionStore.requeueComposerMessageAtFront(item, for: sessionID)
            return
        }
        deliverPiAgentMessage(
            item.message,
            mode: .prompt,
            transcriptText: item.transcriptText,
            titleSource: item.titleSource,
            images: item.images,
            pasteAttachments: item.pasteAttachments,
            session: session
        )
    }

    func isPiAgentSessionActuallyVisible(_ sessionID: UUID) -> Bool {
        NSApp.isActive
            && selectedSidebarItem == .agent
            && piAgentSessionStore.selectedSession?.id == sessionID
            && (NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    func schedulePiAgentCompletionNotification(for sessionID: UUID) {
        pendingPiAgentNotificationTasks[sessionID]?.cancel()
        let delay = UInt64(piAgentNotificationDelay * 1_000_000_000)
        pendingPiAgentNotificationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sendPiAgentCompletionNotificationIfNeeded(for: sessionID)
            }
        }
    }

    func sendPiAgentCompletionNotificationIfNeeded(for sessionID: UUID) {
        pendingPiAgentNotificationTasks[sessionID] = nil
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard session.needsAttention, !isPiAgentSessionActuallyVisible(sessionID), shouldSendPiAgentSystemNotification else { return }
        sendPiAgentCompletionNotification(for: session)
    }

    private var shouldSendPiAgentSystemNotification: Bool {
        !NSApp.isActive || !(NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    func piAgentNotificationIdentifier(for sessionID: UUID) -> String {
        "pi-agent-\(sessionID.uuidString)"
    }

    func sendPiAgentCompletionNotification(for session: PiAgentSessionRecord) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                // .badge is required even though the Dock count is set via
                // NSDockTile.badgeLabel: once an app registers for notifications,
                // the Dock only draws its badge when the per-app "Badge
                // application icon" setting is authorized.
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = LanguageStore.shared.t("vm.piAgentNeedsReview")
                content.body = session.displayTitle
                content.userInfo = [
                    "sessionID": session.id.uuidString,
                    "windowID": windowID.uuidString
                ]

                let request = UNNotificationRequest(
                    identifier: "pi-agent-\(session.id.uuidString)",
                    content: content,
                    trigger: nil
                )

                try await UNUserNotificationCenter.current().add(request)
                self.piAgentSessionStore.updateSession(session.id) { record in
                    record.lastNotificationAt = Date()
                }
            } catch {
                return
            }
        }
    }

    func renamePiAgentSession(_ id: UUID, title: String) {
        piAgentSessionStore.renameSession(id, title: title)
        piAgentRunner.syncSessionName(for: id)
    }

    func setPiAgentSessionPinned(_ id: UUID, pinned: Bool) {
        if pinned, let session = piAgentSessionStore.sessions.first(where: { $0.id == id }) {
            let sectionID: String
            if session.isAgentDeckBuilderSession {
                sectionID = PiAgentSessionGrouping.agentDeckBuilderSectionID
            } else if session.isNoProject {
                sectionID = PiAgentSessionGrouping.noProjectSectionID
            } else if projectByPath[session.projectPath] != nil {
                sectionID = session.projectPath
            } else {
                sectionID = PiAgentSessionGrouping.otherSectionID
            }
            collapsedProjects.remove(sectionID)
        }
        piAgentSessionStore.setSessionPinned(id, pinned: pinned)
    }

    /// Whether the toolbar/menu can open a plain terminal at the selected session's project cwd.
    ///
    /// - Returns: `true` when a session is selected and its launch working directory exists on disk.
    var canOpenSelectedPiAgentSessionInTerminal: Bool {
        guard let session = piAgentSessionStore.selectedSession else { return false }
        var isDir: ObjCBool = false
        let path = session.launchWorkingDirectory.path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }


    func resumeSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        selectedSidebarItem = .agent
        acknowledgePiAgentSession(session.id)
        piAgentRunner.resume(session: session)
    }

}
