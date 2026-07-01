import XCTest
@testable import agent_deck

@MainActor
final class PiAgentSessionGroupingTests: XCTestCase {

    /// Fixed reference instant so recency windows are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - previewSplit

    func testRecentPreviewCappedAtFiveWhenAllOld() throws {
        // 8 sessions outside the (now-removed) 6-hour always-shown window →
        // 5 newest shown, 3 hidden behind Show more. Recency alone no longer
        // promotes sessions beyond the top-N cap; only this-run touches and the
        // current selection can.
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertEqual(split.preview.count, 5)
        XCTAssertEqual(split.hidden.count, 3)
    }

    func testNoSixHourAlwaysVisibleException() throws {
        // The 6-hour always-shown window is removed. Five recent updates within
        // the same day do NOT push beyond the top-5 cap on recency alone — only
        // this-run touches or selection promote beyond the cap.
        let recent = try (0..<8).map { i in
            try makeSession(title: "r\(i)", updatedAt: now.addingTimeInterval(-Double(3600 + i)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: recent, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertEqual(split.preview.count, 5)
        XCTAssertEqual(split.hidden.count, 3)
    }

    func testTouchedThisRunSurfacesAbove5Cap() throws {
        // Sessions older than the top-5 default cap appear in the preview when
        // they were touched during the current app run, mirroring the store's
        // createSession / touchSession(bumpUpdatedAt: true) path.
        let top5 = try (0..<5).map { i in
            try makeSession(title: "top\(i)", updatedAt: now.addingTimeInterval(-Double(1_000 + i)))
        }
        let olderTouched = try makeSession(title: "touched", updatedAt: now.addingTimeInterval(-200_000))
        let olderUntouched = try makeSession(title: "old", updatedAt: now.addingTimeInterval(-300_000))
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: top5 + [olderTouched, olderUntouched],
            isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default,
            exactSort: true, touchedThisRunSessionIDs: [olderTouched.id])
        XCTAssertEqual(split.preview.count, 6)
        XCTAssertTrue(split.preview.contains { $0.id == olderTouched.id })
        XCTAssertFalse(split.preview.contains { $0.id == olderUntouched.id })
        XCTAssertEqual(split.hidden.count, 1)
    }

    func testExactSortUsesExactUpdatedAtWithinSameDay() throws {
        // `sessionListPrecedes` (day-granular) treats same-day messages as equal
        // and orders by createdAt DESC; `sessionListPrecedesExact` respects the
        // within-day updatedAt so a richer chat wins.
        let s1 = try makeSession(
            title: "s1",
            updatedAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-3_600))
        let s2 = try makeSession(
            title: "s2",
            updatedAt: now.addingTimeInterval(-1_800),
            createdAt: now.addingTimeInterval(-7_200))
        let daySorted = [s1, s2].sorted { PiAgentSessionRecord.sessionListPrecedes($0, $1) }
        XCTAssertEqual(daySorted.first?.title, "s1")
        let exactSorted = [s1, s2].sorted { PiAgentSessionRecord.sessionListPrecedesExact($0, $1) }
        XCTAssertEqual(exactSorted.first?.title, "s2")
    }

    func testExactSortPreviewOrderMatchesExactComparator() throws {
        // With `exactSort: true` the preview's row order reflects the strict
        // `sessionListPrecedesExact` comparator, not the day-granular one.
        let s1 = try makeSession(title: "s1", updatedAt: now.addingTimeInterval(-100))
        let s2 = try makeSession(title: "s2", updatedAt: now.addingTimeInterval(-50))
        let s3 = try makeSession(title: "s3", updatedAt: now.addingTimeInterval(-200))
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: [s1, s2, s3], isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default,
            exactSort: true)
        XCTAssertEqual(split.preview.map(\.title), ["s2", "s1", "s3"])
    }

    func testDeletionFollowsExactSortedVisibleOrder() throws {
        // Visible order driving `nextSelectionAfterDeletion` matches the
        // exact-sort preview order, so deleting the most-recent chat picks the
        // next-most-recent visible row, regardless of the underlying store
        // order.
        let sessions = try (0..<6).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * (i + 1))))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: sessions[0].id, now: now, options: .default,
            exactSort: true)
        // sessions[0] is most recent → preview[0]. Deleting it picks preview[1].
        XCTAssertEqual(split.preview.first?.id, sessions[0].id)
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: split.preview, deletedIDs: [sessions[0].id], selectedID: sessions[0].id)
        XCTAssertEqual(next, split.preview[1].id)
    }

    func testWorkingAloneDoesNotPromoteBeyondRecency() throws {
        // `isWorking` is no longer consulted by the preview rule. An older
        // working session stays hidden unless it's also in `touchedThisRunSessionIDs`
        // or is the current selection.
        let oldWorking = try makeSession(title: "working", updatedAt: now.addingTimeInterval(-100_000), status: .running)
        let newer = try (0..<5).map { i in
            try makeSession(title: "newer\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: [oldWorking] + newer, isExpanded: false, capPreviews: true,
            isWorking: { $0.status == .running }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertFalse(split.preview.contains { $0.title == "working" })
    }

    func testWorkingWithTouchedThisRunSurfacesAboveCap() throws {
        // An older working session surfaces when it's also recorded as
        // touched this run, showing that the touch-set (not the working
        // predicate) is what promotes above the cap.
        let oldWorking = try makeSession(title: "working", updatedAt: now.addingTimeInterval(-100_000), status: .running)
        let newer = try (0..<5).map { i in
            try makeSession(title: "newer\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: [oldWorking] + newer, isExpanded: false, capPreviews: true,
            isWorking: { $0.status == .running }, selectedSessionID: nil, now: now, options: .default,
            exactSort: true, touchedThisRunSessionIDs: [oldWorking.id])
        XCTAssertTrue(split.preview.contains { $0.id == oldWorking.id })
    }

    func testSelectedSessionAlwaysShown() throws {
        // An old session that would otherwise be hidden is surfaced because it
        // is the currently selected one.
        let selected = try makeSession(title: "selected", updatedAt: now.addingTimeInterval(-500_000))
        let bucket = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-3600))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: [selected] + bucket, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: selected.id, now: now, options: .default)
        XCTAssertTrue(split.preview.contains { $0.id == selected.id })
        XCTAssertFalse(split.hidden.contains { $0.id == selected.id })
    }

    func testFloorShowsMostRecentWhenAllOld() throws {
        // Fewer than 5 old sessions are all shown.
        let sessions = try (0..<4).map { i in
            try makeSession(title: "old\(i)", updatedAt: now.addingTimeInterval(-Double(200_000 + i * 1000)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertEqual(split.preview.count, 4)
        XCTAssertEqual(split.hidden.count, 0)
    }

    func testPreviewUnionedWithHiddenEqualsAll() throws {
        let sessions = try (0..<10).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 + i * 5000)))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: false, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        let previewIDs = Set(split.preview.map(\.id))
        let hiddenIDs = Set(split.hidden.map(\.id))
        XCTAssertEqual(previewIDs.intersection(hiddenIDs), [])
        XCTAssertEqual(previewIDs.union(hiddenIDs), Set(split.all.map(\.id)))
    }

    // MARK: - previewSplit edge modes

    func testExpandedShowsAll() throws {
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-3600))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: true, capPreviews: true,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertEqual(split.preview.count, 8)
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testCapPreviewsFalseShowsAll() throws {
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-3600))
        }
        let split = PiAgentSessionGrouping.previewSplit(
            sessions: sessions, isExpanded: false, capPreviews: false,
            isWorking: { _ in false }, selectedSessionID: nil, now: now, options: .default)
        XCTAssertEqual(split.preview.count, 8)
        XCTAssertTrue(split.hidden.isEmpty)
    }

    // MARK: - sections

    func testGroupsSortedAlphabeticallyByRepoName() throws {
        // owner/repo → sorts by repo. "agent-deck" < "claude-code-meter".
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let meter = try makeProject(path: "/p/meter", repo: "claude-code-meter", owner: "a-streetcoder")
        let projectByPath = [deck.path: deck, meter.path: meter]
        let sessions = [
            try makeSession(title: "m1", updatedAt: now, projectPath: meter.path),
            try makeSession(title: "d1", updatedAt: now, projectPath: deck.path)
        ]
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: projectByPath, expandedProjectIDs: [],
            collapsedProjectIDs: [],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)
        XCTAssertEqual(sections.map(\.title), ["agent-deck", "claude-code-meter"])
        XCTAssertEqual(sections.first?.subtitle, "a-streetcoder")
        XCTAssertTrue(sections.allSatisfy { $0.isProjectGroup })
    }

    func testOrphansCollectIntoTrailingOtherGroup() throws {
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let sessions = [
            try makeSession(title: "d1", updatedAt: now, projectPath: deck.path),
            try makeSession(title: "orphan", updatedAt: now, projectPath: "/p/ghost")
        ]
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck], expandedProjectIDs: [],
            collapsedProjectIDs: [],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.last?.id, PiAgentSessionGrouping.otherSectionID)
        XCTAssertEqual(sections.last?.title, "Other")
        XCTAssertFalse(sections.last?.isProjectGroup ?? true)
    }

    func testNoProjectSessionsUseDedicatedNonProjectGroup() throws {
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        var noProject = try makeSession(title: "blank", updatedAt: now)
        noProject.projectPath = ""
        noProject.projectName = PiAgentSessionRecord.noProjectDisplayName
        let sessions = [
            try makeSession(title: "d1", updatedAt: now, projectPath: deck.path),
            try makeSession(title: "orphan", updatedAt: now, projectPath: "/p/ghost"),
            noProject
        ]
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck], expandedProjectIDs: [],
            collapsedProjectIDs: [],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)

        XCTAssertEqual(sections.map(\.id), [deck.path, PiAgentSessionGrouping.noProjectSectionID, PiAgentSessionGrouping.otherSectionID])
        XCTAssertEqual(sections[1].title, PiAgentSessionRecord.noProjectDisplayName)
        XCTAssertFalse(sections[1].isProjectGroup)
    }

    func testShowMoreRevealsAllAndReportsTotalCount() throws {
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)), projectPath: deck.path)
        }
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck],
            expandedProjectIDs: [deck.path], collapsedProjectIDs: [],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.items.count, 8)
        XCTAssertEqual(sections.first?.hiddenCount, 0)
        XCTAssertEqual(sections.first?.totalCount, 8)
        XCTAssertTrue(sections.first?.isShowMoreActive ?? false)
    }

    func testCollapsedGroupRendersZeroItems() throws {
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)), projectPath: deck.path)
        }
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck],
            expandedProjectIDs: [], collapsedProjectIDs: [deck.path],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)
        XCTAssertEqual(sections.first?.items.count, 0)
        XCTAssertEqual(sections.first?.hiddenCount, 0)
        XCTAssertEqual(sections.first?.totalCount, 8)
        XCTAssertTrue(sections.first?.isCollapsed ?? false)
    }

    func testCollapsedGroupHidesBeyondFive() throws {
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let sessions = try (0..<8).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(30_000 + i)), projectPath: deck.path)
        }
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck], expandedProjectIDs: [],
            collapsedProjectIDs: [],
            capPreviews: true, isWorking: { _ in false }, selectedSessionID: nil, now: now)
        XCTAssertEqual(sections.first?.items.count, 5)
        XCTAssertEqual(sections.first?.hiddenCount, 3)
        XCTAssertFalse(sections.first?.isShowMoreActive ?? true)
    }

    func testExplicitCollapseHidesSelectedSessionButKeepsCount() throws {
        // Explicit disclosure-collapse wins: the group renders header-only even
        // if it contains the current selection. The total count remains correct
        // so the user can expand it from the header.
        let deck = try makeProject(path: "/p/deck", repo: "agent-deck", owner: "a-streetcoder")
        let sessions = try (0..<4).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-3600), projectPath: deck.path)
        }
        let selected = sessions[3]
        let sections = PiAgentSessionGrouping.sections(
            from: sessions, projectByPath: [deck.path: deck],
            expandedProjectIDs: [], collapsedProjectIDs: [deck.path],
            capPreviews: true, isWorking: { _ in false },
            selectedSessionID: selected.id, now: now)
        XCTAssertEqual(sections.first?.items.count, 0)
        XCTAssertEqual(sections.first?.totalCount, 4)
    }

    // MARK: - nextSelectionAfterDeletion

    /// Three sessions, delete the middle (current) one → the row below it wins.
    func testNextSelectionPicksRowBelowDeletedSelection() throws {
        let sessions = try (0..<3).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: [sessions[1].id], selectedID: sessions[1].id)
        XCTAssertEqual(next, sessions[2].id)
    }

    /// Delete the LAST (current) row → fall back to the row above it.
    func testNextSelectionFallsBackToRowAboveWhenDeletingLast() throws {
        let sessions = try (0..<3).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: [sessions[2].id], selectedID: sessions[2].id)
        XCTAssertEqual(next, sessions[1].id)
    }

    /// Delete the only visible session → nil so the caller clears selection.
    func testNextSelectionReturnsNilWhenNoSurvivors() throws {
        let only = try makeSession(title: "only", updatedAt: now)
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: [only], deletedIDs: [only.id], selectedID: only.id)
        XCTAssertNil(next)
    }

    /// Delete a NON-current row → selection must not move (returns nil), even
    /// when other rows are deleted alongside it.
    func testNextSelectionNilWhenCurrentSelectionSurvives() throws {
        let sessions = try (0..<4).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        // Delete rows 0 and 2 but the current selection is row 1.
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: [sessions[0].id, sessions[2].id],
            selectedID: sessions[1].id)
        XCTAssertNil(next)
    }

    /// Multi-select delete of a NON-CONTIGUOUS set including the selected row
    /// (e.g. delete rows {0,2} where the current selection is row 2): the row
    /// immediately below the selected one wins, NOT a survivor of row 0's gap.
    func testNextSelectionAnchorsOnSelectedRowNotFirstDeleted() throws {
        let sessions = try (0..<5).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        // Delete row 0 and row 2 (the current selection). The natural target is
        // the row right after the selected one (row 3), not row 1.
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: [sessions[0].id, sessions[2].id],
            selectedID: sessions[2].id)
        XCTAssertEqual(next, sessions[3].id)
    }

    /// Contiguous block including the selected row → first survivor below the block.
    func testNextSelectionFindsFirstSurvivorAfterContiguousBlock() throws {
        let sessions = try (0..<6).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        // Delete rows 2,3,4 with the current selection at row 3.
        let deletedIDs: Set<UUID> = [sessions[2].id, sessions[3].id, sessions[4].id]
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: deletedIDs,
            selectedID: sessions[3].id)
        XCTAssertEqual(next, sessions[5].id)
    }

    /// Contiguous block including the selected row that runs to the END of the
    /// list → first survivor ABOVE the block.
    func testNextSelectionFallsUpwardWhenBlockRunsToEnd() throws {
        let sessions = try (0..<5).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        // Delete rows 3,4 with the current selection at row 3.
        let deletedIDs: Set<UUID> = [sessions[3].id, sessions[4].id]
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: deletedIDs,
            selectedID: sessions[3].id)
        XCTAssertEqual(next, sessions[2].id)
    }

    /// Selected row is not in the visible list (hidden behind Show more /
    /// collapsed) but is being deleted → fall back to the first visible survivor.
    func testNextSelectionFallsBackWhenSelectedNotVisible() throws {
        let visible = try (0..<3).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        let hiddenSelected = try makeSession(title: "hidden", updatedAt: now.addingTimeInterval(-200_000))
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: visible, deletedIDs: [hiddenSelected.id], selectedID: hiddenSelected.id)
        XCTAssertEqual(next, visible[0].id)
    }

    /// No current selection at all → nil (don't manufacture a selection from a
    /// delete triggered while there's none).
    func testNextSelectionNilWithNoCurrentSelection() throws {
        let sessions = try (0..<3).map { i in
            try makeSession(title: "s\(i)", updatedAt: now.addingTimeInterval(-Double(3600 * i)))
        }
        let next = PiAgentSessionGrouping.nextSelectionAfterDeletion(
            visibleSessions: sessions, deletedIDs: [sessions[1].id], selectedID: nil)
        XCTAssertNil(next)
    }

    // MARK: - helpers

    private func makeSession(
        title: String,
        updatedAt: Date,
        createdAt: Date? = nil,
        status: PiAgentRunStatus = .idle,
        projectPath: String? = nil
    ) throws -> PiAgentSessionRecord {
        var session = try PiTestSupport.makeParentSession()
        session.title = title
        session.updatedAt = updatedAt
        session.createdAt = createdAt ?? updatedAt
        session.status = status
        if let projectPath {
            session.projectPath = projectPath
            session.projectName = (projectPath as NSString).lastPathComponent
        }
        return session
    }

    private func makeProject(path: String, repo: String, owner: String) throws -> DiscoveredProject {
        DiscoveredProject(
            url: URL(fileURLWithPath: path),
            gitHubRemote: GitHubRemote(
                host: "github.com",
                owner: owner,
                repo: repo,
                remoteURL: "git@github.com:\(owner)/\(repo).git"
            ),
            isGitRepository: true,
            iconFileURL: nil,
            projectType: .unknown,
            fallbackSymbolName: "folder",
            searchIndex: repo
        )
    }
}
