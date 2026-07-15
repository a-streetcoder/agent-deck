import Foundation

/// Groups the All-Projects session list by project and computes, per project,
/// which sessions show by default vs. collapse behind a "Show more" affordance.
///
/// Product rule (defaults in `PiAgentSessionGroupingOptions`): within each
/// project, show the five most-recently updated sessions, plus every session
/// updated in the last six hours (which may take the preview over five). The
/// rest hides behind "Show more". Search and the attention-only filter bypass
/// the cap (the user is hunting, so truncation only gets in the way).
///
/// This module is intentionally Foundation-only (no SwiftUI/AppKit) so the
/// preview rule is unit-testable in isolation.
enum PiAgentSessionGrouping {
    /// Identity of the explicit general-chat group. These sessions are not
    /// project orphans and must not be treated as a discovered-project bucket.
    static let noProjectSectionID = "agent-deck.session-group.no-project"
    static let agentDeckBuilderSectionID = "agent-deck.session-group.agent-deck-builder"

    /// Identity of the trailing catch-all group that holds sessions whose
    /// `projectPath` no longer resolves to a discovered project.
    static let otherSectionID = "agent-deck.session-group.other"

    /// Identity of the flat trailing list shown after focused project groups.
    static let previousSessionsSectionID = "agent-deck.session-group.previous"
    static let previousSessionsPageSize = 15

    /// Splits the filtered global session set into the focused population and
    /// its exact-recency-sorted remainder. The caller supplies the focus rule so
    /// this Foundation-only grouping module does not depend on live runner state.
    static func focusPartition(
        from sessions: [PiAgentSessionRecord],
        matchesFocused: (PiAgentSessionRecord) -> Bool
    ) -> PiAgentSessionFocusPartition {
        let focused = sessions.filter { $0.pinnedAt != nil || matchesFocused($0) }
        let focusedIDs = Set(focused.map(\.id))
        let previous = sessions
            .filter { !focusedIDs.contains($0.id) }
            .sorted { PiAgentSessionRecord.sessionListPrecedesExact($0, $1) }
        return PiAgentSessionFocusPartition(focused: focused, previous: previous)
    }

    /// Applies the flat Previous Sessions reveal limit. Search/filter callers
    /// pass nil to expose every match. A selected older row is unioned into the
    /// preview so selection never points at a hidden session.
    static func previousSessionsSplit(
        sessions: [PiAgentSessionRecord],
        visibleLimit: Int?,
        selectedSessionID: UUID?
    ) -> PiAgentSessionPreviewSplit {
        let sorted = sessions.sorted { PiAgentSessionRecord.sessionListPrecedesExact($0, $1) }
        guard let visibleLimit else {
            return PiAgentSessionPreviewSplit(all: sorted, preview: sorted, hidden: [])
        }

        var visibleIDs = Set(sorted.prefix(max(0, visibleLimit)).map(\.id))
        if let selectedSessionID, sorted.contains(where: { $0.id == selectedSessionID }) {
            visibleIDs.insert(selectedSessionID)
        }
        let preview = sorted.filter { visibleIDs.contains($0.id) }
        let hidden = sorted.filter { !visibleIDs.contains($0.id) }
        return PiAgentSessionPreviewSplit(all: sorted, preview: preview, hidden: hidden)
    }

    /// Split one project's sessions into the preview set and the hidden set.
    ///
    /// - Parameters:
    ///   - sessions: the project's in-scope sessions (order is irrelevant;
    ///     everything is sorted by most-recent update).
    ///   - isExpanded: when `true`, the preview is the entire sorted input and
    ///     nothing is hidden (the user expanded this group).
    ///   - capPreviews: when `false`, previews are uncapped — every session is
    ///     shown. Used while a search query or the attention-only filter is
    ///     active.
    ///   - isWorking: retained for call-site compatibility; the preview rule no
    ///     longer consults it (working sessions surface via `touchedThisRunSessionIDs`
    ///     or the top-N cap instead).
    ///   - selectedSessionID: the currently selected session, always shown so
    ///     selection never lands behind a collapsed group.
    ///   - now: retained as a reference instant for call-site stability; the
    ///     preview rule no longer derives recency windows from it.
    ///   - options: the tunable thresholds.
    ///   - exactSort: when `true`, sort within-day activity by the strict
    ///     `sessionListPrecedesExact` comparator (full `updatedAt` granularity)
    ///     so the expanded/full sidebar's most-recently-touched chat leads.
    ///     Defaults to `false`, preserving the day-granular `sessionListPrecedes`
    ///     used by the compact strip.
    ///   - touchedThisRunSessionIDs: sessions created or touched during the
    ///     current app run. These are surfaced in the preview even when they
    ///     fall outside the top-N most-recent exact-updated sessions, so a
    ///     just-created/jostled older session stays reachable without taking
    ///     the preview over the cap arbitrarily.
    /// - Returns: `all` (the sorted input), `preview` (what to render), and
    ///   `hidden` (what sits behind "Show more"). `preview + hidden == all`.
    static func previewSplit(
        sessions: [PiAgentSessionRecord],
        isExpanded: Bool,
        capPreviews: Bool,
        isWorking: (PiAgentSessionRecord) -> Bool,
        selectedSessionID: UUID?,
        now: Date,
        options: PiAgentSessionGroupingOptions,
        exactSort: Bool = false,
        touchedThisRunSessionIDs: Set<UUID> = []
    ) -> PiAgentSessionPreviewSplit {
        // Sort by either the day-granular comparator (compact strip's stability
        // contract) or the strict exact comparator (expanded/full sidebar's
        // most-recently-touched-first rule). The expanded panel wraps rebuilds
        // in a hybrid freeze so a streaming `updatedAt` bump does not reshuffle
        // rows live; the comparator only decides the natural top-of-list winner
        // once the freeze releases.
        let sorted = sessions.sorted { lhs, rhs in
            sessionListPrecedes(lhs, rhs, exactSort: exactSort)
        }

        // Expanded view or uncapped modes show everything.
        if isExpanded || !capPreviews || sorted.isEmpty {
            return PiAgentSessionPreviewSplit(all: sorted, preview: sorted, hidden: [])
        }

        var includedIDs = Set<UUID>()

        // 1. Show the N most-recently-updated sessions (exact order when the
        //    caller asked for `exactSort`). This is the per-project preview cap.
        for session in sorted.prefix(options.maxRecentPerProject) {
            includedIDs.insert(session.id)
        }

        // 2. Surface sessions touched during the current app run, even when
        //    they fall outside the top-N. These are typically chats the runner
        //    just created or jostled via a follow-up; they should remain
        //    reachable while still respecting the cap for the bulk of old rows.
        if !touchedThisRunSessionIDs.isEmpty {
            for session in sorted where touchedThisRunSessionIDs.contains(session.id) {
                includedIDs.insert(session.id)
            }
        }

        // 3. Keep the current selection reachable even when it is older than
        //    the preview window; explicit disclosure-collapse still wins later.
        if let selectedSessionID {
            includedIDs.insert(selectedSessionID)
        }

        let preview = sorted.filter { includedIDs.contains($0.id) }
        let hidden = sorted.filter { !includedIDs.contains($0.id) }
        return PiAgentSessionPreviewSplit(all: sorted, preview: preview, hidden: hidden)
    }

    /// Expanded grouping keeps pins ahead of normal recency without changing
    /// the store or collapsed-sidebar comparators.
    private static func sessionListPrecedes(
        _ lhs: PiAgentSessionRecord,
        _ rhs: PiAgentSessionRecord,
        exactSort: Bool
    ) -> Bool {
        switch (lhs.pinnedAt, rhs.pinnedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return exactSort
                ? PiAgentSessionRecord.sessionListPrecedesExact(lhs, rhs)
                : PiAgentSessionRecord.sessionListPrecedes(lhs, rhs)
        }
    }

    /// Build the full grouped section list from the scoped+filtered sessions.
    ///
    /// Sessions are partitioned by their (resolvable) `projectPath`; sessions
    /// whose path is no longer discovered collect into a trailing "Other"
    /// group. Groups sort alphabetically by repo name (or folder name), with
    /// "Other" always last — so `a-streetcoder/claude-code-meter` sorts as
    /// "claude-code-meter" and `a-streetcoder/agent-deck` sorts as "agent-deck".
    ///
    /// `exactSort` and `touchedThisRunSessionIDs` are forwarded to
    /// `previewSplit`; the expanded/full sidebar passes `exactSort: true` and
    /// the store's per-run touch set, while the compact strip computes its own
    /// flat list (see `CodingAgentCollapsedPanel.interleaveByLiveness`) and
    /// never calls through here.
    static func sections(
        from sessions: [PiAgentSessionRecord],
        projectByPath: [String: DiscoveredProject],
        expandedProjectIDs: Set<String>,
        collapsedProjectIDs: Set<String>,
        capPreviews: Bool,
        isWorking: (PiAgentSessionRecord) -> Bool,
        selectedSessionID: UUID?,
        now: Date = Date(),
        options: PiAgentSessionGroupingOptions = .default,
        exactSort: Bool = false,
        touchedThisRunSessionIDs: Set<UUID> = []
    ) -> [PiAgentSessionListSection] {
        var byPath: [String: [PiAgentSessionRecord]] = [:]
        var noProjectSessions: [PiAgentSessionRecord] = []
        var agentDeckBuilderSessions: [PiAgentSessionRecord] = []
        var orphans: [PiAgentSessionRecord] = []
        for session in sessions {
            if session.isAgentDeckBuilderSession {
                agentDeckBuilderSessions.append(session)
            } else if session.isNoProject {
                noProjectSessions.append(session)
            } else if projectByPath[session.projectPath] != nil {
                byPath[session.projectPath, default: []].append(session)
            } else {
                orphans.append(session)
            }
        }

        var projectSections: [PiAgentSessionListSection] = []
        projectSections.reserveCapacity(byPath.count + (noProjectSessions.isEmpty ? 0 : 1) + (agentDeckBuilderSessions.isEmpty ? 0 : 1) + (orphans.isEmpty ? 0 : 1))

        for (path, projectSessions) in byPath {
            let project = projectByPath[path]!
            projectSections.append(makeSection(
                id: path,
                title: project.gitHubRemote?.repo ?? project.name,
                subtitle: project.gitHubRemote?.owner,
                iconFileURL: project.iconFileURL,
                fallbackSymbolName: project.fallbackSymbolName,
                assetName: project.projectType.assetName,
                sessions: projectSessions,
                isProjectGroup: true,
                isShowMoreRequested: expandedProjectIDs.contains(path),
                isCollapsed: collapsedProjectIDs.contains(path),
                capPreviews: capPreviews,
                isWorking: isWorking,
                selectedSessionID: selectedSessionID,
                now: now,
                options: options,
                exactSort: exactSort,
                touchedThisRunSessionIDs: touchedThisRunSessionIDs
            ))
        }

        projectSections.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if !noProjectSessions.isEmpty {
            projectSections.append(makeSection(
                id: noProjectSectionID,
                title: PiAgentSessionRecord.noProjectDisplayName,
                subtitle: nil,
                iconFileURL: nil,
                fallbackSymbolName: "bubble.left.and.bubble.right",
                assetName: nil,
                sessions: noProjectSessions,
                isProjectGroup: false,
                isShowMoreRequested: expandedProjectIDs.contains(noProjectSectionID),
                isCollapsed: collapsedProjectIDs.contains(noProjectSectionID),
                capPreviews: capPreviews,
                isWorking: isWorking,
                selectedSessionID: selectedSessionID,
                now: now,
                options: options,
                exactSort: exactSort,
                touchedThisRunSessionIDs: touchedThisRunSessionIDs
            ))
        }

        if !agentDeckBuilderSessions.isEmpty {
            projectSections.append(makeSection(
                id: agentDeckBuilderSectionID,
                title: PiAgentSessionRecord.agentDeckBuilderDisplayName,
                subtitle: nil,
                iconFileURL: nil,
                fallbackSymbolName: "hammer",
                assetName: nil,
                sessions: agentDeckBuilderSessions,
                isProjectGroup: false,
                isShowMoreRequested: expandedProjectIDs.contains(agentDeckBuilderSectionID),
                isCollapsed: collapsedProjectIDs.contains(agentDeckBuilderSectionID),
                capPreviews: capPreviews,
                isWorking: isWorking,
                selectedSessionID: selectedSessionID,
                now: now,
                options: options,
                exactSort: exactSort,
                touchedThisRunSessionIDs: touchedThisRunSessionIDs
            ))
        }

        if !orphans.isEmpty {
            projectSections.append(makeSection(
                id: otherSectionID,
                title: "Other",
                subtitle: nil,
                iconFileURL: nil,
                fallbackSymbolName: "folder",
                assetName: nil,
                sessions: orphans,
                isProjectGroup: false,
                isShowMoreRequested: expandedProjectIDs.contains(otherSectionID),
                isCollapsed: collapsedProjectIDs.contains(otherSectionID),
                capPreviews: capPreviews,
                isWorking: isWorking,
                selectedSessionID: selectedSessionID,
                now: now,
                options: options,
                exactSort: exactSort,
                touchedThisRunSessionIDs: touchedThisRunSessionIDs
            ))
        }

        return projectSections
    }

    /// The session to make current after `deletedIDs` are removed from the
    /// list the user actually sees (`visibleSessions`, in display order).
    ///
    /// Mail-app semantics applied to the flat grouped list: the row that takes
    /// the deleted set's place is the first sibling BELOW it; if the deleted set
    /// runs to the end of the list, the row immediately ABOVE it becomes current.
    /// If nothing remains, returns `nil` (and the caller clears selection).
    ///
    /// `selectedID` anchors the search — when the user deletes a non-current
    /// row (multi-select delete excluding the current one) the selection should
    /// not move, so the helper only returns a non-nil fallback when the current
    /// selection is among the deleted IDs.
    ///
    /// Why this lives here and not on the store: "next" is a property of the
    /// user's visible grouped order (search/attention filters and collapse
    /// state can hide rows the store still knows about). The store sees the
    /// full flat `sessions` array and would otherwise clamp to the globally
    /// most-recent session, which jumps the transcript to an unrelated chat.
    static func nextSelectionAfterDeletion(
        visibleSessions: [PiAgentSessionRecord],
        deletedIDs: Set<UUID>,
        selectedID: UUID?
    ) -> UUID? {
        // No work to do unless the current selection is being deleted —
        // deleting an unrelated row must not move the active session.
        guard let selectedID, deletedIDs.contains(selectedID) else { return nil }

        // Anchor on the selected row's position in the visible list. From there
        // walk downward for the first surviving "row below"; if the deleted set
        // runs to the end (or the selected row was last/hidden), walk upward
        // for the closest surviving "row above". This handles every deletion
        // shape in ONE pass per direction:
        //   - single selected row deleted → the row immediately below it
        //   - contiguous block including selected → first survivor below the block
        //   - non-contiguous multi-select including selected → the row right
        //     next to the selected one (not far away at the first deleted row)
        //   - selected row was last / not visible → the new last visible row
        //   - nothing survives → nil (caller clears selection)
        let visibleIDs = visibleSessions.map(\.id)
        let anchor = visibleIDs.firstIndex(of: selectedID)

        if let anchor, anchor + 1 < visibleIDs.count {
            for id in visibleIDs[(anchor + 1)...] where !deletedIDs.contains(id) {
                return id
            }
        }
        if let anchor, anchor > 0 {
            for index in stride(from: anchor - 1, through: 0, by: -1) where !deletedIDs.contains(visibleIDs[index]) {
                return visibleIDs[index]
            }
        }
        // Selected row wasn't in the visible list (hidden behind Show more /
        // collapsed) but is being deleted — fall back to the first surviving
        // visible row, or nil if the visible list is also emptied.
        return visibleSessions.first(where: { !deletedIDs.contains($0.id) })?.id
    }

    private static func makeSection(
        id: String,
        title: String,
        subtitle: String?,
        iconFileURL: URL?,
        fallbackSymbolName: String,
        assetName: String?,
        sessions: [PiAgentSessionRecord],
        isProjectGroup: Bool,
        isShowMoreRequested requested: Bool,
        isCollapsed: Bool,
        capPreviews: Bool,
        isWorking: (PiAgentSessionRecord) -> Bool,
        selectedSessionID: UUID?,
        now: Date,
        options: PiAgentSessionGroupingOptions,
        exactSort: Bool = false,
        touchedThisRunSessionIDs: Set<UUID> = []
    ) -> PiAgentSessionListSection {
        // Always evaluate the *collapsed* split so we can tell whether the
        // group actually has anything to collapse (a group with ≤ preview-size
        // sessions has nothing to expand). `requested` only sticks when there
        // is hidden content.
        let split = previewSplit(
            sessions: sessions,
            isExpanded: false,
            capPreviews: capPreviews,
            isWorking: isWorking,
            selectedSessionID: selectedSessionID,
            now: now,
            options: options,
            exactSort: exactSort,
            touchedThisRunSessionIDs: touchedThisRunSessionIDs
        )
        let isShowMore = requested && !split.hidden.isEmpty
        // Items rendered: nothing when disclosure-collapsed; every session when
        // "Show more" is active (most-recent update order, not preview+hidden);
        // otherwise the preview set.
        let items: [PiAgentSessionRecord]
        if isCollapsed {
            items = []
        } else if isShowMore {
            items = split.all
        } else {
            items = split.preview
        }
        let hiddenCount = isCollapsed || isShowMore ? 0 : split.hidden.count
        return PiAgentSessionListSection(
            id: id,
            title: title,
            subtitle: subtitle,
            iconFileURL: iconFileURL,
            fallbackSymbolName: fallbackSymbolName,
            assetName: assetName,
            items: items,
            hiddenCount: hiddenCount,
            isShowMoreActive: isShowMore,
            isCollapsed: isCollapsed,
            totalCount: split.all.count,
            isProjectGroup: isProjectGroup
        )
    }
}

/// Tunable thresholds for per-project session previewing. Defaults encode the
/// shipped product rule; kept as a type so tests and future tuning have one
/// knob to turn.
struct PiAgentSessionGroupingOptions: Equatable, Sendable {
    /// Maximum most-recent sessions shown per project before the rest collapse
    /// behind "Show more". Sessions touched during the current app run and the
    /// currently-selected session are surfaced on top of this cap.
    var maxRecentPerProject: Int = 5

    static let `default` = PiAgentSessionGroupingOptions()
}

/// Result of `PiAgentSessionGrouping.previewSplit`. `preview + hidden == all`,
/// and all three are in most-recent update order.
struct PiAgentSessionPreviewSplit: Equatable {
    let all: [PiAgentSessionRecord]
    let preview: [PiAgentSessionRecord]
    let hidden: [PiAgentSessionRecord]
}

/// One section of the grouped session list: a project (or the catch-all
/// "Other") plus the sessions to render for it. Plain `Equatable` data (no
/// SwiftUI) so `SessionListContent`'s `.equatable()` gate can compare it
/// cheaply and skip rebuilds on streaming pulses.
struct PiAgentSessionFocusPartition: Equatable {
    let focused: [PiAgentSessionRecord]
    let previous: [PiAgentSessionRecord]
}

enum PiAgentSessionListSectionStyle: Equatable {
    case project
    case previous
}

struct PiAgentSessionListSection: Equatable, Identifiable {
    /// Stable identity: the project path, or `PiAgentSessionGrouping.otherSectionID`.
    let id: String
    /// Header title — the GitHub repo name, or the folder name; "Other" for the
    /// catch-all.
    let title: String
    /// Muted header subtitle — the GitHub owner, when known.
    let subtitle: String?
    /// Custom project artwork, forwarded to `ProjectIconView`.
    let iconFileURL: URL?
    /// SF Symbol fallback for `ProjectIconView`.
    let fallbackSymbolName: String
    /// Asset-catalog artwork name for `ProjectIconView` (`projectType.assetName`).
    let assetName: String?
    /// Sessions rendered in this section, in display order. Empty when the
    /// group is disclosure-collapsed; otherwise the preview set, or every
    /// session when "Show more" is active.
    let items: [PiAgentSessionRecord]
    /// Sessions hidden behind "Show more". `0` when collapsed, when "Show
    /// more" is already active, or when nothing is hidden — in which case no
    /// affordance renders.
    let hiddenCount: Int
    /// Whether "Show more" is active for this group (drives "Show less").
    /// Only true when the group has collapsible content.
    let isShowMoreActive: Bool
    /// Whether the group is disclosure-collapsed to just its header (no
    /// sessions rendered). Drives the header chevron direction.
    let isCollapsed: Bool
    /// Total sessions belonging to this group (rendered + hidden).
    let totalCount: Int
    /// Controls whether rows use the rich project presentation or the compact
    /// Previous Sessions presentation.
    var style: PiAgentSessionListSectionStyle = .project
    /// True for real discovered projects; false for no-project utility groups and the
    /// catch-all "Other" group.
    let isProjectGroup: Bool

    /// The header's "new session" affordance renders for real projects and
    /// no-project utility groups, but never for orphaned "Other".
    var canCreateSession: Bool {
        isProjectGroup || id == PiAgentSessionGrouping.noProjectSectionID || id == PiAgentSessionGrouping.agentDeckBuilderSectionID
    }

    /// Returns a copy of this section with `items` replaced. Used by the
    /// expanded panel's hybrid freeze, which preserves the prior visible row
    /// order during active work without rebuilding the rest of the section.
    func withItems(_ items: [PiAgentSessionRecord]) -> PiAgentSessionListSection {
        PiAgentSessionListSection(
            id: id,
            title: title,
            subtitle: subtitle,
            iconFileURL: iconFileURL,
            fallbackSymbolName: fallbackSymbolName,
            assetName: assetName,
            items: items,
            hiddenCount: hiddenCount,
            isShowMoreActive: isShowMoreActive,
            isCollapsed: isCollapsed,
            totalCount: totalCount,
            style: style,
            isProjectGroup: isProjectGroup
        )
    }
}
