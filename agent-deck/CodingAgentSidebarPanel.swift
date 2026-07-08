import SwiftUI

/// Single definition of what "session matches the search query" means, shared
/// by the expanded panel's full list and the collapsed panel's recents so the
/// toolbar search filters both identically.
extension PiAgentSessionRecord {
    static let activeActivityInterval: TimeInterval = 1_800

    var lastActivityAt: Date {
        [lastUserMessageAt, Optional(updatedAt), lastNotificationAt].compactMap { $0 }.max() ?? updatedAt
    }

    func hasRecentActivity(referenceDate: Date = Date()) -> Bool {
        lastActivityAt >= referenceDate.addingTimeInterval(-Self.activeActivityInterval)
    }

    func matchesActiveSessionsFilter(
        referenceDate: Date = Date(),
        isWorking: Bool = false,
        hasActiveLoop: Bool = false,
        hasPendingUIRequest: Bool = false
    ) -> Bool {
        status == .draft || status.isActive || isWorking || hasActiveLoop || hasRecentActivity(referenceDate: referenceDate) || needsAttention || hasPendingUIRequest
    }

    func matchesSessionSearch(_ query: String) -> Bool {
        [
            title,
            projectName,
            projectPath,
            repository ?? "",
            issueNumber.map(String.init) ?? "",
            lastSummary ?? ""
        ]
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(query)
    }
}

/// Header row shared by both states of the Coding Agent pull-up panel: the
/// fixed Sessions title, a per-state trailing slot (new-session controls,
/// delete), and the expand/collapse chevron. The whole row is tappable; inner
/// buttons take gesture priority so their own actions still win.
struct CodingAgentPanelHeader<Trailing: View>: View {
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Sessions")
                .font(AppTheme.Font.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing

            AppCircleIconButton(
                style: .neutral,
                size: 30,
                help: isExpanded ? "Collapse to navigation" : "Show all sessions",
                action: onToggle
            ) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            }
            .accessibilityLabel(isExpanded ? "Collapse sessions" : "Expand sessions")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

/// New-session control shared by the collapsed and expanded panel headers.
/// The Sessions panel is always global, so `+` always opens the project picker.
/// Starting a 1:1 agent chat lives in the draft's Deck-agents card, next to
/// the agents themselves, so the header stays a single button.
struct CodingAgentNewSessionControls: View {
    let viewModel: AppViewModel

    var body: some View {
        PiAgentAddSessionMenuButton(
            projects: orderedProjects,
            selectedProject: nil,
            action: { viewModel.createNoProjectPiAgentDraft() },
            onSelectAgentDeckBuilder: { viewModel.createAgentDeckBuilderDraft() },
            onSelectProject: { viewModel.createPiAgentDraft(for: $0) }
        )
    }

    private var orderedProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Collapsed state of the Coding Agent pull-up panel: header + the session
/// list inline (visually capped at six rows, scrollable beyond that), so
/// resuming a chat is one click without expanding. Lives at the bottom of the
/// nav sidebar, just above the project/GitHub card.
struct CodingAgentCollapsedPanel: View {
    let viewModel: AppViewModel
    let store: PiAgentSessionStore
    /// The same toolbar search the expanded list filters on, so searching
    /// narrows the recents too.
    let sessionSearchText: String

    /// Cached so `body` never reads `store.sessions` directly — `touchSession`
    /// mutates that array many times per second during streaming. Rebuilt only
    /// on the non-streaming triggers that actually change the list, mirroring
    /// the expanded panel's `cachedSections`.
    @State private var recentSessions: [PiAgentSessionRecord] = []
    /// On-demand jump consumed by the list's `AppList`; set when this panel
    /// becomes the visible one so the selected session scrolls into view.
    @State private var recentScrollRequest: UUID?
    @State private var pendingDeleteSessionID: UUID?
    @State private var isDeleteSessionAlertPresented = false

    /// Rows shown before the list scrolls.
    private static let visibleRecentRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodingAgentPanelHeader(
                isExpanded: false,
                onToggle: { viewModel.expandCodingAgentPanel() }
            ) {
                PiAgentActiveSessionsFilterButton(isOn: activeFilterBinding)
                CodingAgentNewSessionControls(viewModel: viewModel)
            }
            // 8 (card) + 6 here = a 14pt content inset, matching the account
            // card at the top of the sidebar.
            .padding(.horizontal, 6)
            .padding(.top, 2)

            Rectangle()
                .fill(AppTheme.contentStroke)
                .frame(height: 1)
                .padding(.horizontal, 6)

            if !recentSessions.isEmpty {
                CodingAgentRecentList(
                    sessions: recentSessions,
                    selectedSessionID: store.selectedSessionID,
                    isAgentSelected: viewModel.selectedSidebarItem == .agent,
                    workingSessionIDs: workingRecentSessionIDs,
                    uiRequestSessionIDs: uiRequestRecentSessionIDs,
                    activeLoopSessionIDs: activeLoopRecentSessionIDs,
                    projectByPath: viewModel.projectByPath,
                    bottomContentInset: recentListFadeHeight > 0 ? recentListFadeHeight + 2 : 4,
                    scrollRequestID: recentScrollRequest,
                    scrollRequest: $recentScrollRequest,
                    onSelect: { viewModel.selectPiAgentSession($0) },
                    onDelete: { id in
                        pendingDeleteSessionID = id
                        isDeleteSessionAlertPresented = true
                    }
                )
                .equatable()
                .frame(height: recentListHeight)
                .bottomEdgeFade(height: recentListFadeHeight)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appContentSurface(cornerRadius: 16)
        .onAppear {
            rebuildRecents()
            recentScrollRequest = store.selectedSessionID
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildRecents() }
        .onChange(of: sessionSearchText) { _, _ in rebuildRecents() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildRecents() }
        .onChange(of: viewModel.showPiAgentActiveOnly) { _, _ in rebuildRecents() }
        .onChange(of: store.uiRequestsBySessionID) { _, _ in rebuildRecents() }
        .onChange(of: store.subagentRunsRevision) { _, _ in rebuildRecents() }
        .onChange(of: store.loopRunsRevision) { _, _ in rebuildRecents() }
        // The expanded panel stays mounted while this one shows (and vice
        // versa), so collapsing is the moment to re-sync this list's scroll
        // offset with whatever session was picked in the expanded list.
        .onChange(of: viewModel.isCodingAgentPanelExpanded) { _, isExpanded in
            if !isExpanded { recentScrollRequest = store.selectedSessionID }
        }
        // Keep the selected row in view whenever selection changes — a newly
        // created session is selected by `createPiAgentDraft`, and without this
        // the strip would just highlight it offscreen if the user was scrolled
        // down. Gated on the collapsed state (expanded mode hides this strip via
        // opacity 0, so scrolling it would be wasted work and could realize lazy
        // rows the user never sees). The same value backing the row's selection
        // highlight is observed here, so no extra derivation per body eval.
        .onChange(of: store.selectedSessionID) { _, newID in
            guard !viewModel.isCodingAgentPanelExpanded, let newID else { return }
            recentScrollRequest = newID
        }
        .alert("Delete Pi Agent session?", isPresented: $isDeleteSessionAlertPresented) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteSessionID {
                    viewModel.deletePiAgentSessions([id])
                }
                pendingDeleteSessionID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteSessionID = nil }
        } message: {
            Text("This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName).")
        }
    }

    /// Hugs the content up to `visibleRecentRows` rows, then locks so the rest
    /// scrolls. Mirrors AppList's internal geometry (row spacing + the 4pt
    /// bottom content padding).
    private var recentListHeight: CGFloat {
        let rows = CGFloat(min(recentSessions.count, Self.visibleRecentRows))
        return rows * CodingAgentRecentRow.rowHeight
            + max(0, rows - 1) * AppListMetrics.rowSpacing
            + 4
    }

    /// Fade only when there is hidden content to hint at; a fade over a
    /// fully-visible list just dims the last row.
    private var recentListFadeHeight: CGFloat {
        recentSessions.count > Self.visibleRecentRows ? 24 : 0
    }

    private var workingRecentSessionIDs: Set<UUID> {
        Set(recentSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var uiRequestRecentSessionIDs: Set<UUID> {
        Set(recentSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

    private var activeLoopRecentSessionIDs: Set<UUID> {
        let recentIDs = Set(recentSessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            recentIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }

    private var activeFilterBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showPiAgentActiveOnly },
            set: { viewModel.showPiAgentActiveOnly = $0 }
        )
    }

    private func rebuildRecents() {
        var scoped = store.sessions
        if viewModel.showPiAgentAttentionOnly {
            scoped = scoped.filter(\.needsAttention)
        }
        if viewModel.showPiAgentActiveOnly {
            let now = Date()
            let pendingUIRequestSessionIDs = Set(store.uiRequestsBySessionID.keys)
            let activeLoopSessionIDs = activeLoopSessionIDs(in: scoped)
            scoped = scoped.filter {
                $0.matchesActiveSessionsFilter(
                    referenceDate: now,
                    isWorking: viewModel.piAgentSessionIsWorking($0),
                    hasActiveLoop: activeLoopSessionIDs.contains($0.id),
                    hasPendingUIRequest: pendingUIRequestSessionIDs.contains($0.id)
                )
            }
        }
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            scoped = scoped.filter { $0.matchesSessionSearch(query) }
        }
        // Sessions are always global now: project selection in other views must
        // not change the session strip.
        let next = interleaveByLiveness(scoped)
        if next != recentSessions { recentSessions = next }
        // Report the collapsed strip's flat visible row snapshot to the view
        // model so keyboard navigation operates on rendered rows only. Only
        // reports when this strip is the active panel (i.e. the expanded panel
        // is hidden); the expanded panel owns the report when it's showing.
        if !viewModel.isCodingAgentPanelExpanded {
            viewModel.piAgentVisibleSessionsForNavigation = next
        }
    }

    /// Live sessions (working / updated in the last 30 min) first in
    /// recency order, then the remaining sessions in recency order. Used only
    /// for the All-Projects compact strip.
    private func interleaveByLiveness(_ sessions: [PiAgentSessionRecord]) -> [PiAgentSessionRecord] {
        let recentCutoff = Date().addingTimeInterval(-PiAgentSessionRecord.activeActivityInterval)
        let activeLoopSessionIDs = activeLoopSessionIDs(in: sessions)
        let liveIDs = Set(sessions.filter {
            viewModel.piAgentSessionIsWorking($0) || activeLoopSessionIDs.contains($0.id) || $0.lastActivityAt >= recentCutoff
        }.map(\.id))
        let sortRecency: (PiAgentSessionRecord, PiAgentSessionRecord) -> Bool = {
            PiAgentSessionRecord.sessionListPrecedes($0, $1)
        }
        let live = sessions.filter { liveIDs.contains($0.id) }.sorted(by: sortRecency)
        let rest = sessions.filter { !liveIDs.contains($0.id) }.sorted(by: sortRecency)
        return live + rest
    }

    private func activeLoopSessionIDs(in sessions: [PiAgentSessionRecord]) -> Set<UUID> {
        let sessionIDs = Set(sessions.map(\.id))
        return Set(store.loopRunsBySessionID.compactMap { sessionID, runs in
            sessionIDs.contains(sessionID) && runs.contains(where: \.isActive) ? sessionID : nil
        })
    }
}

/// Equatable boundary for the recents — the collapsed panel's body re-evaluates
/// on streaming-adjacent triggers (working IDs, project map churn), and this
/// keeps those pulses from re-laying-out the rows unless something a row
/// actually shows changed. Mirrors `SessionListContent`'s discipline.
private struct CodingAgentRecentList: View, Equatable {
    let sessions: [PiAgentSessionRecord]
    let selectedSessionID: UUID?
    let isAgentSelected: Bool
    let workingSessionIDs: Set<UUID>
    let uiRequestSessionIDs: Set<UUID>
    let activeLoopSessionIDs: Set<UUID>
    let projectByPath: [String: DiscoveredProject]
    /// Past the panel's fade when one shows, so the last row can scroll clear
    /// of the gradient. Derived from the session count, so `==` already
    /// covers it via `sessions`.
    let bottomContentInset: CGFloat
    /// Snapshot of `scrollRequest`'s value at construction, compared in `==`.
    /// The binding can't be compared there: both sides read the same live
    /// state storage, so old-vs-new is always equal and the gate would
    /// swallow the request.
    let scrollRequestID: UUID?
    let scrollRequest: Binding<UUID?>
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void

    static func == (lhs: CodingAgentRecentList, rhs: CodingAgentRecentList) -> Bool {
        lhs.sessions == rhs.sessions
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.isAgentSelected == rhs.isAgentSelected
            && lhs.workingSessionIDs == rhs.workingSessionIDs
            && lhs.uiRequestSessionIDs == rhs.uiRequestSessionIDs
            && lhs.activeLoopSessionIDs == rhs.activeLoopSessionIDs
            && lhs.projectByPath == rhs.projectByPath
            // A pending scroll request must defeat the gate so the inner
            // AppList's onChange sees it (same trap as SessionListContent).
            && lhs.scrollRequestID == rhs.scrollRequestID
    }

    var body: some View {
        AppList(
            sections: [AppListSection(id: "recents", title: nil, items: sessions)],
            selection: .single(selectionBinding),
            rowHorizontalPadding: 0,
            rowVerticalPadding: 0,
            listHorizontalInset: 0,
            bottomContentInset: bottomContentInset,
            scrollRequest: scrollRequest
        ) { session in
            CodingAgentRecentRow(
                session: session,
                project: projectByPath[session.projectPath],
                isSelected: isAgentSelected && session.id == selectedSessionID,
                isRunning: workingSessionIDs.contains(session.id),
                hasUIRequest: uiRequestSessionIDs.contains(session.id),
                hasActiveLoop: activeLoopSessionIDs.contains(session.id),
                onDelete: { onDelete(session.id) }
            )
            .equatable()
        }
    }

    /// AppList paints selection from this binding; reads resolve against the
    /// agent tab being current (no highlight while another tab is selected),
    /// writes route through the view model's session selection.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { isAgentSelected ? selectedSessionID : nil },
            set: { if let id = $0 { onSelect(id) } }
        )
    }
}

/// Compact one-line session row for the collapsed panel: project icon, title,
/// and a live status slot (spinner while a loop runs, typing dots while running,
/// bell when waiting; a hover swaps it for the delete affordance). Selection/hover
/// chrome and the tap come from the enclosing `AppList` row.
struct CodingAgentRecentRow: View, Equatable {
    let session: PiAgentSessionRecord
    let project: DiscoveredProject?
    let isSelected: Bool
    let isRunning: Bool
    let hasUIRequest: Bool
    let hasActiveLoop: Bool
    let onDelete: () -> Void

    /// Fixed so the collapsed panel can size its visible window exactly.
    static let rowHeight: CGFloat = 33

    // Closures intentionally excluded: when the value inputs match, the retained
    // instance's closure captured the same session id, so it stays correct.
    static func == (lhs: CodingAgentRecentRow, rhs: CodingAgentRecentRow) -> Bool {
        lhs.session == rhs.session
            && lhs.project == rhs.project
            && lhs.isSelected == rhs.isSelected
            && lhs.isRunning == rhs.isRunning
            && lhs.hasUIRequest == rhs.hasUIRequest
            && lhs.hasActiveLoop == rhs.hasActiveLoop
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProjectIconView(
                imageURL: iconImageURL,
                symbolName: iconSymbolName,
                size: 18,
                assetName: iconAssetName
            )
            .opacity(isSelected || hasUIRequest || hasActiveLoop || isRunning || session.needsAttention ? 1 : 0.58)

            HoverMarqueeTitleText(text: session.displayTitle, isHovering: isHovering)
                .font(AppTheme.Font.footnote.weight(.medium))
                .fontWidth(.expanded)
                .foregroundStyle(.primary)
                // Same seen-inactive dimming as the expanded rows.
                .opacity(isSelected || hasUIRequest || hasActiveLoop || isRunning || session.needsAttention ? 1 : 0.58)
                .layoutPriority(1)

            Spacer(minLength: 6)

            ZStack(alignment: .trailing) {
                statusSlot
                    .opacity(isHovering ? 0 : 1)
                    .allowsHitTesting(false)
                deleteButton
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        // 8 (card) + 6 here = 14pt content inset, aligned with the header.
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(session.displayTitle)
    }

    var iconImageURL: URL? {
        session.isNoProject ? nil : project?.iconFileURL
    }

    var iconSymbolName: String {
        session.isAgentDeckBuilderSession ? "hammer" : (session.isNoProject ? "bubble.left.and.bubble.right" : (project?.fallbackSymbolName ?? "folder"))
    }

    var iconAssetName: String? {
        session.isNoProject ? nil : project?.projectType.assetName
    }

    @ViewBuilder
    private var statusSlot: some View {
        if hasUIRequest {
            Image(systemName: "questionmark.bubble.fill")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.brandAccent)
                .help("Pi Agent is waiting for your response")
                .accessibilityLabel("Waiting for your response")
        } else if hasActiveLoop {
            AppSpinner()
                .controlSize(.small)
                .frame(width: 14, height: 14)
                .help("Loop running")
                .accessibilityLabel("Loop running")
        } else if isRunning {
            PiAgentTypingIndicator()
        } else if session.needsAttention {
            Image(systemName: "bell.fill")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.brandAccent)
                .help("Pi Agent finished and needs review")
                .accessibilityLabel("Needs review")
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(AppTheme.Font.caption.weight(.semibold))
        }
        .appSmallSecondaryButton()
        .help("Delete session")
        .accessibilityLabel("Delete session")
    }
}
