import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionListContent: View, Equatable {
    let sections: [PiAgentSessionListSection]
    /// Render per-project group headers. False for the single-project scoped
    /// view, which renders one anonymous section identical to the pre-grouping
    /// flat layout.
    let isGrouped: Bool
    let selectedSessionIDs: Set<UUID>
    let workingSessionIDs: Set<UUID>
    let uiRequestSessionIDs: Set<UUID>
    let generatingTitleIDs: Set<UUID>
    let activeLoopSessionIDs: Set<UUID>
    let activityByID: [UUID: PiAgentSessionGitActivity]
    let projectByPath: [String: DiscoveredProject]
    let compactSessionIDs: Set<UUID>
    /// Snapshot of `scrollRequest`'s value at construction, compared in `==`.
    /// The binding itself can't be compared: both sides read the same live
    /// state storage, so old-vs-new is always equal and the gate would
    /// swallow the request.
    var scrollRequestID: UUID? = nil
    /// Forwarded to `AppList` so the owner can bring the selected session back
    /// into view when this list becomes the visible one (panel expand).
    var scrollRequest: Binding<UUID?> = .constant(nil)

    @Binding var selection: Set<UUID>
    let onSelect: (PiAgentSessionRecord) -> Void
    let onDelete: (UUID) -> Void
    let onSetPinned: (UUID, Bool) -> Void
    let onShowMorePrevious: () -> Void
    /// Deletes the complete scoped/filtered Previous partition, not just its paginated preview.
    var onDeletePrevious: (() -> Void)? = nil
    /// Toggle a project group's "Show more/less" state.
    let onToggleExpand: (String) -> Void
    /// Toggle a project group's disclosure collapse (header-only / expanded).
    let onToggleCollapse: (String) -> Void
    /// Start a new session scoped to the given project/group id. Handles real
    /// project groups and the dedicated General Chat group; no-op for "Other".
    let onCreateSessionForProject: (String) -> Void
    /// Arrow-key navigation (↑/↓), routed through the same view-model path as
    /// ⌘]/⌘[ so both follow the grouped list with auto-reveal. `nil` disables
    /// arrows (lists that don't need keyboard nav).
    var onArrowNavigate: ((MoveCommandDirection) -> Void)? = nil

    static func == (lhs: SessionListContent, rhs: SessionListContent) -> Bool {
        let diff: String?
        if lhs.sections != rhs.sections { diff = "sections" }
        else if lhs.selectedSessionIDs != rhs.selectedSessionIDs { diff = "selectedSessionIDs" }
        else if lhs.workingSessionIDs != rhs.workingSessionIDs { diff = "workingSessionIDs" }
        else if lhs.uiRequestSessionIDs != rhs.uiRequestSessionIDs { diff = "uiRequestSessionIDs" }
        else if lhs.generatingTitleIDs != rhs.generatingTitleIDs { diff = "generatingTitleIDs" }
        else if lhs.activeLoopSessionIDs != rhs.activeLoopSessionIDs { diff = "activeLoopSessionIDs" }
        else if lhs.activityByID != rhs.activityByID { diff = "activityByID" }
        else if lhs.projectByPath != rhs.projectByPath { diff = "projectByPath" }
        else if lhs.compactSessionIDs != rhs.compactSessionIDs { diff = "compactSessionIDs" }
        // A pending scroll request must defeat the equatable gate, or the
        // inner AppList's onChange never sees the new value and the jump to
        // the selected row silently doesn't happen.
        else if lhs.scrollRequestID != rhs.scrollRequestID { diff = "scrollRequest" }
        else { diff = nil }
#if DEBUG
        if let diff, TranscriptScrollProfiler.verboseTrace {
            if diff == "selectedSessionIDs" {
                // Selection churn with no user click has shown up in scroll
                // traces; print the actual delta so the mutator can be named.
                let old = lhs.selectedSessionIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
                let new = rhs.selectedSessionIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ",")
                SessionListContent.perfLog.error("SessionListContent re-eval — selectedSessionIDs changed: [\(old, privacy: .public)] -> [\(new, privacy: .public)]")
            } else {
                SessionListContent.perfLog.error("SessionListContent re-eval — input changed: \(diff, privacy: .public)")
            }
        }
#endif
        return diff == nil
    }

#if DEBUG
    private static let perfLog = Logger(subsystem: "works.earendil.pi-deck", category: "SessionListPerf")
#endif

    var body: some View {
        AppList(
            sections: appSections,
            selection: .multi($selection),
            keyboardNavigation: onArrowNavigate != nil,
            onArrowNavigate: onArrowNavigate,
            cornerRadius: AppTheme.Chat.subCardCornerRadius,
            rowHorizontalPadding: 0,
            rowVerticalPadding: 0,
            listHorizontalInset: 6,
            // Past the 34pt fade below, so the last session can scroll clear
            // of the gradient instead of always sitting dimmed in it.
            bottomContentInset: 36,
            scrollRequest: scrollRequest
        ) { session in
            row(session)
        }
        .animation(.snappy(duration: 0.24), value: sections.flatMap(\.items).map(\.id))
        .bottomEdgeFade(height: 34)
    }

    /// With no focused/current sessions, the previous list is the entire list,
    /// so it belongs directly below the panel's Sessions heading.
    private var rendersPreviousSessionsInline: Bool {
        sections.contains(where: { $0.style == .previous })
            && !sections.contains(where: { $0.style == .project })
    }

    /// Map the value-type `PiAgentSessionListSection`s to `AppListSection`s,
    /// attaching a custom project-group header to any section that needs one.
    private var appSections: [AppListSection<PiAgentSessionRecord>] {
        sections.map { section in
            AppListSection(
                id: section.id,
                header: section.style == .previous
                    ? (rendersPreviousSessionsInline
                        ? nil
                        : AnyView(PiAgentPreviousSessionsHeader(onDelete: onDeletePrevious)))
                    : (shouldShowHeader(for: section)
                        ? AnyView(PiAgentSessionGroupHeader(
                            section: section,
                            onToggleCollapse: { onToggleCollapse(section.id) },
                            onCreateSession: { onCreateSessionForProject(section.id) }
                        ))
                        : nil),
                footer: footer(for: section),
                items: section.items
            )
        }
    }

    /// A header renders whenever the list is grouped — every group needs a
    /// disclosure + identity, now that groups can collapse to just their
    /// header. A single-project scoped view (`isGrouped == false`) stays
    /// headerless, identical to the pre-grouping flat layout.
    private func shouldShowHeader(for section: PiAgentSessionListSection) -> Bool {
        isGrouped
    }

    private func footer(for section: PiAgentSessionListSection) -> AnyView? {
        if section.style == .previous {
            guard section.hiddenCount > 0 else { return nil }
            return AnyView(PiAgentPreviousSessionsFooter(hiddenCount: section.hiddenCount, onShowMore: onShowMorePrevious))
        }
        guard isGrouped && !section.isCollapsed && (section.hiddenCount > 0 || section.isShowMoreActive) else { return nil }
        return AnyView(PiAgentSessionGroupFooter(
            section: section,
            onToggleShowMore: { onToggleExpand(section.id) }
        ))
    }

    @ViewBuilder
    private func row(_ session: PiAgentSessionRecord) -> some View {
        Group {
            if compactSessionIDs.contains(session.id) {
                CodingAgentRecentRow(
                    session: session,
                    project: projectByPath[session.projectPath],
                    isSelected: selectedSessionIDs.contains(session.id),
                    isRunning: workingSessionIDs.contains(session.id),
                    hasUIRequest: uiRequestSessionIDs.contains(session.id),
                    hasActiveLoop: activeLoopSessionIDs.contains(session.id),
                    onDelete: { onDelete(session.id) }
                )
                .equatable()
                .simultaneousGesture(TapGesture().onEnded { onSelect(session) })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(LanguageStore.shared.t("agent.openSession", session.chromeTitle))
                .accessibilityAction { onSelect(session) }
                .focusable()
                .onKeyPress(.space) {
                    onSelect(session)
                    return .handled
                }
            } else {
                PiAgentSessionRow(
                    session: session,
                    isSelected: selectedSessionIDs.contains(session.id),
                    isRunning: workingSessionIDs.contains(session.id),
                    hasUIRequest: uiRequestSessionIDs.contains(session.id),
                    isGeneratingTitle: generatingTitleIDs.contains(session.id),
                    hasActiveLoop: activeLoopSessionIDs.contains(session.id),
                    gitActivity: activityByID[session.id] ?? .none,
                    onSelect: { onSelect(session) },
                    onDelete: { onDelete(session.id) }
                )
                .equatable()
            }
        }
        .contextMenu {
            Button {
                onSetPinned(session.id, session.pinnedAt == nil)
            } label: {
                Label(
                    session.pinnedAt == nil
                        ? LanguageStore.shared.t("session.pin")
                        : LanguageStore.shared.t("session.unpin"),
                    systemImage: session.pinnedAt == nil ? "pin" : "pin.slash"
                )
            }
            Divider()
            Button(role: .destructive) {
                onDelete(session.id)
            } label: {
                Label(
                    selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1
                        ? LanguageStore.shared.t("session.deleteSelected")
                        : LanguageStore.shared.t("session.delete"),
                    systemImage: "trash"
                )
            }
        }
    }
}

/// Localized help/a11y for the session-group “+” control.
func sectionCreateSessionHelp(for section: PiAgentSessionListSection) -> String {
    if section.id == PiAgentSessionGrouping.noProjectSectionID {
        return LanguageStore.shared.t("session.newGeneralChat")
    }
    if section.id == PiAgentSessionGrouping.agentDeckBuilderSectionID {
        return LanguageStore.shared.t("session.newDeckBuilder")
    }
    return LanguageStore.shared.t("session.newInProject", section.title)
}

/// Per-project group header for the All-Projects session list: a disclosure
/// project icon, repo name (primary) + owner (muted), an inline disclosure
/// chevron that collapses the group to its header, a "Show N more / Show less"
/// affordance when the group has capped content, and a trailing `+` that
/// starts a new session in that project. Rendered through
/// `AppListSection.header`, so it inherits `AppList`'s section spacing.
struct PiAgentSessionGroupHeader: View {
    let section: PiAgentSessionListSection
    let onToggleCollapse: () -> Void
    let onCreateSession: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(alignment: .center, spacing: 8) {
                    ProjectIconView(
                        imageURL: section.iconFileURL,
                        symbolName: section.fallbackSymbolName,
                        size: 30,
                        assetName: section.assetName
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 5) {
                            Text(section.title)
                                .font(AppTheme.Font.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 11, height: 11, alignment: .center)
                                .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                                .animation(.snappy(duration: 0.22), value: section.isCollapsed)
                        }
                        if let subtitle = section.subtitle {
                            Text(subtitle)
                                .font(AppTheme.Font.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 30, alignment: .center)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(section.isCollapsed ? LanguageStore.shared.t("session.expandSection") : LanguageStore.shared.t("session.collapseSection"))

            if section.canCreateSession {
                Button(action: onCreateSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(isHovering ? AppTheme.contentSubtleFill : Color.clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30, alignment: .center)
                .help(sectionCreateSessionHelp(for: section))
                .accessibilityLabel(sectionCreateSessionHelp(for: section))
            }
        }
        // Aligns the icon's leading edge with the session row title (row text
        // sits at listHorizontalInset 6 + the row's own 8pt padding = 14pt).
        .padding(.horizontal, 8)
        .frame(minHeight: 34, alignment: .center)
        .onHover { isHovering = $0 }
    }
}

struct PiAgentSessionGroupFooter: View {
    let section: PiAgentSessionListSection
    let onToggleShowMore: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggleShowMore) {
            Text(section.isShowMoreActive ? LanguageStore.shared.t("session.showLess") : LanguageStore.shared.t("session.showMore"))
                .font(AppTheme.Font.footnote.weight(.semibold))
                .foregroundStyle(isHovering ? AppTheme.brandAccentBright : AppTheme.brandAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? AppTheme.brandAccent.opacity(0.10) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help(
            section.isShowMoreActive
                ? LanguageStore.shared.t("session.showFewer")
                : LanguageStore.shared.t(
                    section.hiddenCount == 1 ? "session.showHiddenOne" : "session.showHiddenMany",
                    section.hiddenCount
                )
        )
    }
}

struct PiAgentPreviousSessionsHeader: View {
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(LanguageStore.shared.t("session.previous"))
                .font(AppTheme.Font.footnote.weight(.semibold))
                .fontWidth(.expanded)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            PiAgentPreviousSessionsDeleteButton(onDelete: onDelete, isHoveredExternally: isHovering)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.contentStroke)
                .frame(height: 1)
                .padding(.horizontal, 2)
        }
    }
}

struct PiAgentPreviousSessionsDeleteButton: View {
    let onDelete: (() -> Void)?
    var isHoveredExternally = false

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(role: .destructive, action: { onDelete?() }) {
            Image(systemName: "trash")
                .font(AppTheme.Font.footnote.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Keyboard focus reveals the same reserved slot as hover, without
        // making the destructive control mouse-clickable while hidden.
        .focusable()
        .focused($isFocused)
        .foregroundStyle(.red)
        .opacity((isHovering || isHoveredExternally || isFocused) && onDelete != nil ? 1 : 0)
        .allowsHitTesting((isHovering || isHoveredExternally || isFocused) && onDelete != nil)
        .help(LanguageStore.shared.t("session.deleteAllPrevious"))
        .accessibilityLabel(LanguageStore.shared.t("session.deleteAllPrevious"))
        .onHover { isHovering = $0 }
    }
}

struct PiAgentPreviousSessionsFooter: View {
    let hiddenCount: Int
    let onShowMore: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onShowMore) {
            Text(LanguageStore.shared.t("session.showMore"))
                .font(AppTheme.Font.footnote.weight(.semibold))
                .foregroundStyle(isHovering ? AppTheme.brandAccentBright : AppTheme.brandAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? AppTheme.brandAccent.opacity(0.10) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .help(
            LanguageStore.shared.t(
                "session.showMorePrevious",
                min(hiddenCount, PiAgentSessionGrouping.previousSessionsPageSize)
            )
        )
    }
}

/// Expanded state of the Coding Agent pull-up panel: the full searchable
/// session list that overlays the upper nav sections when the panel is pulled
/// up (see `mainContent`'s sidebar ZStack).
struct CodingAgentExpandedPanel: View {
    let viewModel: AppViewModel
    let store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    /// True only while the panel is expanded. Both panel states are kept
    /// permanently mounted (ZStack in `mainContent`) so the pull-up is a cheap
    /// opacity/offset animation rather than a teardown/rebuild — but that means
    /// this view also stays alive while collapsed. `isActive` gates the only
    /// per-streaming-tick work (the git-activity parse) so the hidden panel
    /// costs nothing during a streaming run.
    let isActive: Bool
    let onCollapse: () -> Void

    @State private var cachedSections: [PiAgentSessionListSection] = []
    @State private var hasBuiltVisibleSessions = false
    // Cached so `body` never reads `store.sessions` directly: `touchSession`
    // mutates that array many times per second during streaming, and a live read
    // here would re-evaluate the whole body at ~30Hz (visible or not). Recomputed
    // only on the non-streaming triggers that actually change the list.
    @State private var hasAnyScopedSessions = false
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var pendingDeleteIsPreviousSessions = false
    @State private var pendingDeletePreviousSearchQuery: String?
    @State private var isDeleteSessionsAlertPresented = false
    @State private var isHoveringPreviousSessionsDeleteButton = false
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State private var postExpandTask: Task<Void, Never>?
    /// Per-session memo of the last activity parse, keyed by the store's
    /// `gitActivityRevision` it was computed at. That revision bumps exactly
    /// when a commit/push/merge entry lands, so a memo entry parsed at the
    /// current revision can never be stale. `rebuildSessionActivityCache`
    /// re-parses only on actual git events — without this, every panel expand
    /// re-scanned every visible transcript synchronously on the main thread,
    /// right as the expand animation's first frames rendered.
    @State private var activityParseMemo: [UUID: (revision: Int, activity: PiAgentSessionGitActivity)] = [:]
    /// Set when the panel becomes the visible one so the list jumps to the
    /// current session (which may have been picked from the collapsed recents
    /// while this list sat hidden at a stale scroll offset).
    @State private var sessionScrollRequest: UUID?
    @State private var previousSessionsVisibleLimit = PiAgentSessionGrouping.previousSessionsPageSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            PiAgentSessionSearchField(text: $sessionSearchText)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if !rendersPreviousSessionsInline {
                Rectangle()
                    .fill(AppTheme.contentStroke)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if isActive && !hasBuiltVisibleSessions {
                // Lightweight placeholder during the expand animation's first
                // frames: computing visibleSections (grouping) or even reading
                // hasAnyScopedSessions here would force synchronous work that
                // competes with the spring animation. After the deferred
                // schedulePostExpandWork rebuild lands, this branch disappears.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasAnyScopedSessions {
                AppEmptyState(LanguageStore.shared.t("session.empty"), systemImage: "square.and.pencil", description: emptySessionsMessage, layout: .fill)
            } else if visibleSections.isEmpty {
                AppEmptyState(LanguageStore.shared.t("session.noneFound"), systemImage: "magnifyingglass", description: LanguageStore.shared.t("session.trySearch"), layout: .fill)
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
                    compactSessionIDs: previousVisibleSessionIDs,
                    scrollRequestID: sessionScrollRequest,
                    scrollRequest: $sessionScrollRequest,
                    selection: $selectedSessionIDs,
                    onSelect: { session in
                        selectSessionFromList(session)
                    },
                    onDelete: { id in requestDeleteSessions(selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [id]) },
                    onSetPinned: { id, pinned in setSessionPinned(id, pinned: pinned) },
                    onShowMorePrevious: showMorePreviousSessions,
                    onDeletePrevious: requestDeletePreviousSessions,
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
        // Full-bleed: the card chrome belongs to the collapsed state only —
        // expanding sheds the container so the list gets the whole sidebar.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if isActive {
                // Defer the initial rebuild/sync past the expand animation's
                // first frames so grouping, selection reconciliation, and git
                // activity parsing don't fight the spring for main-thread time.
                // The placeholder branch above covers the gap.
                schedulePostExpandWork()
            } else {
                // Background prebuild while hidden — no animation to compete
                // with, so the next expand shows the list immediately.
                rebuildVisibleSessions()
                syncVisibleSessionSelection()
                syncMultiSelectionToSelectedSession()
            }
        }
        .onDisappear {
            postExpandTask?.cancel()
            postExpandTask = nil
        }
        .onChange(of: isActive) { _, active in
            if active {
                schedulePostExpandWork()
            } else {
                postExpandTask?.cancel()
                postExpandTask = nil
            }
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.uiRequestsBySessionID) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.subagentRunsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.loopRunsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.expandedProjects) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: viewModel.collapsedProjects) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        // Projects load asynchronously after sessions on first launch; without
        // this trigger the cached sections stayed grouped under "Other" until a
        // later rebuild (the original first-launch "all Other" symptom).
        .onChange(of: viewModel.discoveredProjectsRevision) { _, _ in rebuildVisibleSessionsDeferredIfNeeded() }
        .onChange(of: store.selectedSession?.id) { _, _ in
            rebuildVisibleSessionsDeferredIfNeeded()
            syncMultiSelectionToSelectedSession()
            // Rebuild first so a selected older Previous session is included
            // before AppList consumes the scroll request.
            Task { @MainActor in
                await Task.yield()
                sessionScrollRequest = store.selectedSession?.id
            }
        }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
            rebuildSessionActivityCache()
        }
        // A row can move from Previous Sessions to a rich focused group without
        // changing the flattened visible IDs. Rebuild so its Git strip appears
        // immediately instead of waiting for an unrelated transcript event.
        .onChange(of: richVisibleSessionIDs) { _, _ in
            rebuildSessionActivityCache()
        }
        // Git activity is derived by scanning visible transcripts. Do not run it
        // on the first expand frame: that frame is already resizing/laying out the
        // sidebar and `ScrollViewReader.scrollTo` can realize many lazy rows.
        .onChange(of: store.gitActivityRevision) { _, _ in
            if isActive { rebuildSessionActivityCache() }
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button(LanguageStore.shared.t("common.delete"), role: .destructive) {
                let deleteIDs = pendingDeleteSessionIDs
                let nextID = PiAgentSessionGrouping.nextSelectionAfterDeletion(
                    visibleSessions: visibleSessions,
                    deletedIDs: deleteIDs,
                    selectedID: store.selectedSession?.id
                )
                viewModel.deletePiAgentSessions(deleteIDs, fallbackSelectionID: nextID)
                resetPendingSessionDelete()
            }
            Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { resetPendingSessionDelete() }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private var header: some View {
        CodingAgentPanelHeader(
            isExpanded: true,
            onToggle: onCollapse
        ) {
            if selectedSessionIDs.count > 1 {
                Button(role: .destructive) { requestDeleteSessions(selectedSessionIDs) } label: {
                    Image(systemName: "trash.fill")
                        .font(AppTheme.Font.body.weight(.semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(LanguageStore.shared.t("session.deleteSelected"))
            } else if rendersPreviousSessionsInline {
                PiAgentPreviousSessionsDeleteButton(
                    onDelete: requestDeletePreviousSessions,
                    isHoveredExternally: isHoveringPreviousSessionsDeleteButton
                )
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .onHover { isHoveringPreviousSessionsDeleteButton = $0 }
            }
            CodingAgentNewSessionControls(viewModel: viewModel)
        }
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        store.sessions
    }

    private var isAllProjects: Bool { true }

    private var visibleSections: [PiAgentSessionListSection] {
        // When active and not yet built, the placeholder branch is rendering —
        // return [] so `.onChange(of: visibleSessionIDs)` and other getters
        // referencing visibleSections don't compute grouping synchronously
        // during the expand animation. When inactive, allow computedSections()
        // for the background prebuild path (no animation to compete with).
        if !hasBuiltVisibleSessions { return isActive ? [] : computedSections() }
        return cachedSections
    }

    /// Flattened rendered sessions for selection, navigation, and deletion.
    /// Rows hidden by a collapsed focused project are intentionally excluded.
    private var visibleSessions: [PiAgentSessionRecord] { visibleSections.flatMap(\.items) }

    private var richVisibleSessions: [PiAgentSessionRecord] {
        visibleSections.filter { $0.style == .project }.flatMap(\.items)
    }

    private var previousVisibleSessionIDs: Set<UUID> {
        Set(visibleSections.filter { $0.style == .previous }.flatMap(\.items).map(\.id))
    }

    /// With no focused/current sessions, the previous list is the entire list,
    /// so it belongs directly below the panel's Sessions heading.
    private var rendersPreviousSessionsInline: Bool {
        visibleSections.contains(where: { $0.style == .previous })
            && !visibleSections.contains(where: { $0.style == .project })
    }

    private var richVisibleSessionIDs: [UUID] { richVisibleSessions.map(\.id) }
    private var visibleSessionIDs: [UUID] { visibleSessions.map(\.id) }

    private func schedulePostExpandWork() {
        postExpandTask?.cancel()
        postExpandTask = Task { @MainActor in
            // Let the panel's expand animation and first layout pass get on
            // screen before forcing a ScrollViewReader jump or parsing transcript
            // git activity. Doing both synchronously on activation caused the
            // expanded sidebar to hitch and could trip AppKit layout recursion.
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, isActive else { return }
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            sessionScrollRequest = store.selectedSession?.id
            rebuildSessionActivityCache()
            postExpandTask = nil
        }
    }

    /// Guarded rebuild for reactive `.onChange` triggers: during the deferred
    /// first-expand window (`isActive && !hasBuiltVisibleSessions`), reschedule
    /// `schedulePostExpandWork` instead of rebuilding immediately — a reactive
    /// rebuild would set `hasBuiltVisibleSessions = true` and kill the
    /// placeholder before the expand animation finishes. Once the initial build
    /// has landed, rebuilds happen immediately as before.
    private func rebuildVisibleSessionsDeferredIfNeeded() {
        if isActive && !hasBuiltVisibleSessions {
            schedulePostExpandWork()
        } else {
            rebuildVisibleSessions()
        }
    }

    private func rebuildVisibleSessions() {
        let scoped = scopedSessions
        if hasAnyScopedSessions != !scoped.isEmpty { hasAnyScopedSessions = !scoped.isEmpty }
        let computed = computedSections(from: scoped)
        // Pragmatic hybrid freeze: while any visible session is actively
        // working, preserve the existing visible row order so a streaming
        // `updatedAt` bump doesn't reshuffle rows live. Only newly-present
        // rows (typically just-created or this-run-touched sessions surfacing
        // from the cap) may join the visible list; they're appended in their
        // natural computed order without re-sorting the frozen rows. Once no
        // session is working, the next rebuild re-sorts via the exact rule.
        let next = freezeVisibleOrderDuringActiveWork(computed) ?? computed
        if !hasBuiltVisibleSessions || next != cachedSections {
            cachedSections = next
        }
        hasBuiltVisibleSessions = true
        // Publish the visible row snapshot to the view model so keyboard
        // navigation (⌘]/⌘[ and in-list ↑/↓) operates on rendered rows only —
        // no navigation into hidden preview/collapsed rows, no auto-reveal.
        // Only the active panel reports in, so the collapsed strip's flat
        // list isn't overwritten while the expanded panel is hidden.
        if isActive {
            viewModel.piAgentVisibleSessionsForNavigation = visibleSessions
        }
    }

    /// Returns a frozen copy of `computed` preserving the prior visible row
    /// order, or `nil` when no freeze should apply (no working session, or the
    /// cache isn't populated yet). Frozen sections keep the cached `items`
    /// order with two adjustments per section: drop rows that are no longer
    /// present, and append newly-present rows (newly visible this rebuild).
    /// Structural changes (collapse / Show more toggle) bypass the freeze so
    /// those user actions take effect immediately.
    private func freezeVisibleOrderDuringActiveWork(_ computed: [PiAgentSessionListSection]) -> [PiAgentSessionListSection]? {
        let anyWorking = computed.flatMap(\.items).contains { viewModel.piAgentSessionIsWorking($0) }
        guard anyWorking, hasBuiltVisibleSessions, !cachedSections.isEmpty else { return nil }
        let cachedPins = Dictionary(uniqueKeysWithValues: cachedSections.flatMap(\.items).compactMap { session in
            session.pinnedAt.map { (session.id, $0) }
        })
        let computedPins = Dictionary(uniqueKeysWithValues: computed.flatMap(\.items).compactMap { session in
            session.pinnedAt.map { (session.id, $0) }
        })
        // Pinning is an explicit structural action. Let its promotion/reordering
        // take effect immediately even while another session is streaming.
        guard cachedPins == computedPins else { return nil }
        var frozeAny = false
        let frozen = computed.map { newSection -> PiAgentSessionListSection in
            guard let oldSection = cachedSections.first(where: { $0.id == newSection.id }),
                  // Skip the freeze when the user's collapse / Show-more state
                  // changed between rebuilds — let the new section win so the
                  // structural action takes effect immediately.
                  oldSection.isCollapsed == newSection.isCollapsed,
                  oldSection.isShowMoreActive == newSection.isShowMoreActive else {
                return newSection
            }
            let newByID = Dictionary(uniqueKeysWithValues: newSection.items.map { ($0.id, $0) })
            let oldIDs = Set(oldSection.items.map(\.id))
            // Preserve prior order, refreshing payloads of rows still present.
            var merged = oldSection.items.compactMap { newByID[$0.id] }
            // Insert newly-present rows at their natural computed position
            // relative to the frozen rows. Appending them made a freshly-created
            // draft appear at the bottom whenever another session was working,
            // even though the list sorts newest-first.
            for newItem in newSection.items where !oldIDs.contains(newItem.id) {
                let newIndex = newSection.items.firstIndex(where: { item in item.id == newItem.id })
                let followingFrozenID = newIndex.flatMap { index in
                    newSection.items[(index + 1)...].first(where: { item in oldIDs.contains(item.id) })?.id
                }
                if let followingFrozenID,
                   let insertIndex = merged.firstIndex(where: { item in item.id == followingFrozenID }) {
                    merged.insert(newItem, at: insertIndex)
                } else {
                    merged.append(newItem)
                }
            }
            if merged == newSection.items { return newSection }
            frozeAny = true
            return newSection.withItems(merged)
        }
        return frozeAny ? frozen : nil
    }

    private func computedSections(from scoped: [PiAgentSessionRecord]? = nil) -> [PiAgentSessionListSection] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partition = sessionPartition(from: scoped)

        // This permanently represents the former focused-filter result, which
        // was intentionally uncapped: every focused session remains visible in
        // its project group.
        var sections = PiAgentSessionGrouping.sections(
            from: partition.focused,
            projectByPath: viewModel.projectByPath,
            projectDiscoveryComplete: viewModel.hasCompletedInitialProjectDiscovery,
            expandedProjectIDs: viewModel.expandedProjects,
            collapsedProjectIDs: viewModel.collapsedProjects,
            capPreviews: false,
            isWorking: { viewModel.piAgentSessionIsWorking($0) },
            selectedSessionID: store.selectedSession?.id,
            exactSort: true,
            touchedThisRunSessionIDs: viewModel.piAgentSessionsTouchedThisRunIDs
        )
        if !partition.previous.isEmpty {
            let previousSplit = PiAgentSessionGrouping.previousSessionsSplit(
                sessions: partition.previous,
                visibleLimit: query.isEmpty && !viewModel.showPiAgentAttentionOnly ? previousSessionsVisibleLimit : nil,
                selectedSessionID: store.selectedSession?.id
            )
            sections.append(PiAgentSessionListSection(
                id: PiAgentSessionGrouping.previousSessionsSectionID,
                title: LanguageStore.shared.t("session.previous"),
                subtitle: nil,
                iconFileURL: nil,
                fallbackSymbolName: "clock",
                assetName: nil,
                items: previousSplit.preview,
                hiddenCount: previousSplit.hidden.count,
                isShowMoreActive: false,
                isCollapsed: false,
                totalCount: previousSplit.all.count,
                style: .previous,
                isProjectGroup: false
            ))
        }
        return sections
    }

    private func showMorePreviousSessions() {
        previousSessionsVisibleLimit += PiAgentSessionGrouping.previousSessionsPageSize
        rebuildVisibleSessionsDeferredIfNeeded()
    }

    /// Resolve the full Previous partition at activation time. This deliberately
    /// precedes pagination, so a header delete includes rows behind "Show more"
    /// while still respecting the current search and attention filters.
    private func requestDeletePreviousSessions() {
        let ids = Set(sessionPartition().previous.map(\.id))
        guard !ids.isEmpty else { return }
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDeleteSessionIDs = ids
        pendingDeleteIsPreviousSessions = true
        pendingDeletePreviousSearchQuery = query.isEmpty ? nil : query
        isDeleteSessionsAlertPresented = true
    }

    private func sessionPartition(from scoped: [PiAgentSessionRecord]? = nil) -> PiAgentSessionFocusPartition {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedSource = scoped ?? scopedSessions
        let attentionFiltered = viewModel.showPiAgentAttentionOnly ? scopedSource.filter(\.needsAttention) : scopedSource
        let filtered = query.isEmpty ? attentionFiltered : attentionFiltered.filter { $0.matchesSessionSearch(query) }
        let now = Date()
        let pendingUIRequestSessionIDs = Set(store.uiRequestsBySessionID.keys)
        let loopSessionIDs = activeLoopSessionIDs(in: filtered)
        return PiAgentSessionGrouping.focusPartition(from: filtered) {
            $0.id == viewModel.transientFocusedPiAgentSessionID
                || $0.matchesActiveSessionsFilter(
                    referenceDate: now,
                    isWorking: viewModel.piAgentSessionIsWorking($0),
                    hasActiveLoop: loopSessionIDs.contains($0.id),
                    hasPendingUIRequest: pendingUIRequestSessionIDs.contains($0.id)
                )
        }
    }

    private var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var uiRequestVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.compactMap { session in
            store.uiRequestsBySessionID[session.id] == nil ? nil : session.id
        })
    }

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        Dictionary(uniqueKeysWithValues: visibleSessions.compactMap { session in
            sessionActivityCache[session.id].map { (session.id, $0) }
        })
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

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return LanguageStore.shared.t("session.emptyForProject", project.name)
        }
        return LanguageStore.shared.t("session.emptyHint")
    }

    private var deleteSessionsAlertTitle: String {
        if pendingDeleteIsPreviousSessions {
            return pendingDeleteSessionIDs.count == 1
                ? LanguageStore.shared.t("session.deletePreviousTitle")
                : LanguageStore.shared.t("session.deletePreviousTitleMany", pendingDeleteSessionIDs.count)
        }
        return pendingDeleteSessionIDs.count == 1
            ? LanguageStore.shared.t("session.deleteTitle")
            : LanguageStore.shared.t("session.deleteTitleMany", pendingDeleteSessionIDs.count)
    }

    private var deleteSessionsAlertMessage: String {
        if pendingDeleteIsPreviousSessions {
            let scope: String
            if let query = pendingDeletePreviousSearchQuery {
                scope = LanguageStore.shared.t(
                    "session.deletePreviousScopeMatch",
                    pendingDeleteSessionIDs.count,
                    query
                )
            } else {
                scope = LanguageStore.shared.t(
                    "session.deletePreviousScope",
                    pendingDeleteSessionIDs.count
                )
            }
            return LanguageStore.shared.t("session.deletePreviousMessage", scope)
        }
        return pendingDeleteSessionIDs.count == 1
            ? LanguageStore.shared.t("session.deleteMessage")
            : LanguageStore.shared.t("session.deleteMessageMany")
    }

    private func requestDeleteSessions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteSessionIDs = ids
        pendingDeleteIsPreviousSessions = false
        pendingDeletePreviousSearchQuery = nil
        isDeleteSessionsAlertPresented = true
    }

    private func resetPendingSessionDelete() {
        pendingDeleteSessionIDs = []
        pendingDeleteIsPreviousSessions = false
        pendingDeletePreviousSearchQuery = nil
    }

    private func setSessionPinned(_ id: UUID, pinned: Bool) {
        viewModel.setPiAgentSessionPinned(id, pinned: pinned)
        Task { @MainActor in
            await Task.yield()
            sessionScrollRequest = id
        }
    }

    private func syncVisibleSessionSelection() {
        // Selection validity is owned by ONE canonical rule on the view model
        // (project scope only — never this panel's search/attention filters).
        // Panels asserting selection from their own filtered scope fought each
        // other and ping-ponged the transcript through session switches.
        viewModel.reconcileSelectedSessionWithProjectScope()
    }

    private func syncMultiSelectionToSelectedSession() {
        guard let selectedID = store.selectedSession?.id else {
            if !selectedSessionIDs.isEmpty { selectedSessionIDs = [] }
            lastSelectedSessionID = nil
            return
        }
        // A list click has already written the (possibly multi) selection,
        // including the session it just made current — collapsing to a single
        // here was what killed ⌘/⇧ multi-select the instant it was made. Only
        // reset when the current session jumped OUTSIDE the set (keyboard
        // shortcuts, notification taps, new drafts).
        if !selectedSessionIDs.contains(selectedID) {
            selectedSessionIDs = [selectedID]
        }
        lastSelectedSessionID = selectedID
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        var next = selectedSessionIDs.intersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) { next.insert(selectedID) }
        if next != selectedSessionIDs { selectedSessionIDs = next }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            selectedSessionIDs.formUnion(visibleSessionIDs[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)])
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

    private func rebuildSessionActivityCache() {
        // Only ever called while visible: `activityRevisionToken` is constant while
        // hidden so the driving `.onChange` doesn't fire. The guard is belt-and-
        // suspenders against the `visibleSessionIDs` trigger firing while hidden.
        guard isActive else { return }
        var fresh: [UUID: PiAgentSessionGitActivity] = [:]
        var memo = activityParseMemo
        var memoChanged = false
        let revision = store.gitActivityRevision
        for session in richVisibleSessions {
            let activity: PiAgentSessionGitActivity
            if let cached = memo[session.id], cached.revision == revision {
                activity = cached.activity
            } else {
                activity = piAgentSessionGitActivity(from: store.transcriptsBySessionID[session.id] ?? [])
                memo[session.id] = (revision, activity)
                memoChanged = true
            }
            if activity.hasCommit || activity.hasPush || activity.hasMerge { fresh[session.id] = activity }
        }
        // Drop memo entries for sessions no longer visible so the dictionary
        // can't grow unboundedly across project/search switches.
        if memo.count > richVisibleSessions.count * 2 {
            let visibleIDs = Set(richVisibleSessions.map(\.id))
            memo = memo.filter { visibleIDs.contains($0.key) }
            memoChanged = true
        }
        if memoChanged { activityParseMemo = memo }
        if fresh != sessionActivityCache { sessionActivityCache = fresh }
    }
}

