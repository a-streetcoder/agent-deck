import AppKit
import OSLog
import SwiftUI

struct SkillsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill assignment")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Catalog", "Agent Deck scans skills from bundled, user, project, compatibility, package, and imported external locations.")
                infoRow("Default", "Default skills are passed to every parent Pi Agent session with explicit --skill flags.")
                infoRow("Project", "Project assignments are passed only to parent sessions for that project.")
                infoRow("Agents", "Deck agents receive only skills explicitly assigned to that agent.")
            }

            Text("Discovery does not inject a skill. Agent Deck launches with --no-skills and passes only assigned skills using --skill <path>.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
            Text(description)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum SkillWarningSelection: Identifiable, Hashable {
    case missing(SkillReferenceWarning)
    case diagnostic(DiagnosticWarning)

    var id: String {
        switch self {
        case let .missing(warning): return "missing:\(warning.id)"
        case let .diagnostic(warning): return "diagnostic:\(warning.id)"
        }
    }

    var title: String {
        switch self {
        case let .missing(warning): return warning.missingSkill
        case .diagnostic: return "Skill Warning"
        }
    }

    var subtitle: String {
        switch self {
        case let .missing(warning): return "Referenced by \(warning.agentName) in \(warning.project.name)"
        case .diagnostic: return "Skill catalog issue"
        }
    }
}

struct SkillListMetadata {
    let isAssigned: Bool
    let hasWarnings: Bool
    /// Globally enabled, or enabled for the currently-selected project — drives
    /// the active/catalog split. Cached so the split isn't an O(skills) project-
    /// preference scan on every body eval.
    let isActiveForCurrentProject: Bool
}

private enum SkillDetailSummaryState: Equatable {
    case loading
    case ready(String)
    case failed(String)
}

struct SkillsScreen: View {
    private static let layoutLog = Logger(subsystem: "streetcoding.agent-deck", category: "ResourceLayout")
    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var selectedSkillIDs: Set<SkillRecord.ID> = []
    @State private var skillsPendingBatchDeletion: [SkillRecord]?
    @State private var selectedWarning: SkillWarningSelection?
    @State private var isImportSheetPresented = false
    @State private var importSummaryMessage: String?
    @State private var skillActionErrorMessage: String?
    @State private var skillPendingDeletion: SkillRecord?
    @State private var skillPendingRemoval: SkillRecord?
    @State private var skillsPendingBatchRemoval: [SkillRecord]?
    @State private var skillPendingRename: SkillRecord?
    @State private var skillEditTarget: MarkdownFileEditTarget?
    @State private var newSkillDraft: NewSkillDraft?
    @State private var isCheckingSkillUpdate = false
    @State private var isUpdatingSkillRepository = false
    @State private var skillUpdateStatusMessage: String?
    @State private var skillUpdateConflict: SkillUpdateConflictContext?
    @State private var isRenamingSkillName = false
    @State private var draftSkillName = ""
    @State private var isSkillNameHovered = false
    @FocusState private var isSkillNameFocused: Bool
    @State private var skillRenameErrorMessage: String?
    @State private var detailSummariesBySkillID: [SkillRecord.ID: SkillDetailSummaryState] = [:]
    // Cached sectioning + filtered list + per-row inactive map. The full
    // build runs `Dictionary(grouping:)` + sort + multi-field search +
    // sectioning over `viewModel.allVisibleSkillRecords` — recomputing it on
    // every body eval (every selection click, hover, scroll) was the
    // dominant cost. Recompute only when an actual input changes
    // (snapshot, search, project, metadata revision). Mirrors the pattern
    // in `AgentLibraryPane`.
    @State private var cachedLayout: (
        sections: [AppListSection<SkillRecord>],
        inactiveByID: [SkillRecord.ID: Bool],
        managedSkills: [SkillRecord]
    ) = ([], [:], [])

    var body: some View {
        skillsScreenWithSheets
            .alert("Skill Import", isPresented: Binding(
                get: { importSummaryMessage != nil },
                set: { if !$0 { importSummaryMessage = nil } }
            )) {
                Button("OK") { importSummaryMessage = nil }
            } message: {
                Text(importSummaryMessage ?? "")
            }
            .alert("Skill Assignment", isPresented: Binding(
                get: { skillActionErrorMessage != nil },
                set: { if !$0 { skillActionErrorMessage = nil } }
            )) {
                Button("OK") { skillActionErrorMessage = nil }
            } message: {
                Text(skillActionErrorMessage ?? "")
            }
            .alert("Delete Skill?", isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ), presenting: skillPendingDeletion) { skill in
                Button("Move to Trash", role: .destructive) { deleteSkill(skill) }
                Button("Cancel", role: .cancel) { skillPendingDeletion = nil }
            } message: { skill in
                Text("Move \"\(skill.name)\" to the Trash and remove its Default, project, and agent assignments?")
            }
            .alert("Delete Skills?", isPresented: Binding(
                get: { skillsPendingBatchDeletion != nil },
                set: { if !$0 { skillsPendingBatchDeletion = nil } }
            ), presenting: skillsPendingBatchDeletion) { skills in
                Button("Move \(skills.count) to Trash", role: .destructive) { batchDeleteSkills(skills) }
                Button("Cancel", role: .cancel) { skillsPendingBatchDeletion = nil }
            } message: { skills in
                Text("Move \(skills.count) skills to the Trash and remove their Default, project, and agent assignments?")
            }
            .alert("Remove Skill?", isPresented: Binding(
                get: { skillPendingRemoval != nil },
                set: { if !$0 { skillPendingRemoval = nil } }
            ), presenting: skillPendingRemoval) { skill in
                Button("Remove from Catalog") { removeSkill(skill) }
                Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
            } message: { skill in
                Text("Remove \"\(skill.name)\" from the \(AppBrand.displayName) catalog and clear its Default, project, and agent assignments? The skill files are not deleted — a Git-synced clone is kept.")
            }
            .alert("Remove Skills?", isPresented: Binding(
                get: { skillsPendingBatchRemoval != nil },
                set: { if !$0 { skillsPendingBatchRemoval = nil } }
            ), presenting: skillsPendingBatchRemoval) { skills in
                Button("Remove \(skills.count) from Catalog") { batchRemoveSkills(skills) }
                Button("Cancel", role: .cancel) { skillsPendingBatchRemoval = nil }
            } message: { skills in
                Text("Remove \(skills.count) skills from the \(AppBrand.displayName) catalog and clear their assignments? The skill files are not deleted.")
            }
            .alert("Skill Updates", isPresented: Binding(
                get: { viewModel.skillBatchActionMessage != nil },
                set: { if !$0 { viewModel.skillBatchActionMessage = nil } }
            )) {
                Button("OK") { viewModel.skillBatchActionMessage = nil }
            } message: {
                Text(viewModel.skillBatchActionMessage ?? "")
            }
    }

    private var skillsScreenCore: some View {
        SplitView {
            if viewModel.hasCompletedInitialRefresh {
                skillLibraryContent
                    .appDebugLayout("Skills.libraryPane", logger: Self.layoutLog)
            } else {
                AppLoadingView("Loading skills…")
                    .appDebugLayout("Skills.libraryLoading", logger: Self.layoutLog)
            }
        } detail: {
            if viewModel.hasCompletedInitialRefresh {
                // `lazy: true` — AppPage wraps cards in a vertical ScrollView; a plain
                // VStack measures every card up front, so a wide one reports a ~1500pt
                // ideal width that balloons this pane. A LazyVStack only sums on-screen
                // cards, bounding that ideal.
                AppPage(
                    selectedWarning?.title ?? skillDetailTitle,
                    subtitle: selectedWarning?.subtitle ?? skillDetailSubtitle,
                    lazy: true
                ) {
                    skillDetailContent
                }
                .appDebugLayout("Skills.detail selected=\(selectedSkill?.name ?? selectedWarning?.title ?? "nil")", logger: Self.layoutLog)
            } else {
                AppLoadingView("Loading skill details…")
                    .appDebugLayout("Skills.detailLoading", logger: Self.layoutLog)
            }
        }
        .appDebugLayout("Skills.hsplit", logger: Self.layoutLog)
        .onAppear {
            #if DEBUG
            Self.layoutLog.debug("Skills.state event=appear selectedIDs=\(selectedSkillIDs.count, privacy: .public) selected=\(selectedSkill?.name ?? "nil", privacy: .public) project=\(viewModel.selectedDiscoveredProject?.name ?? "nil", privacy: .public)")
            #endif
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.allVisibleSkillRecords) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        // `cachedSkillMetadataByID` is rebuilt alongside `displayAgentsRevision`
        // in `rebuildWarningCaches()`, so this catches "user toggled a skill
        // onto an agent/project" without needing a separate revision counter
        // or expensive dictionary diff.
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in
            cachedLayout = recomputeLayout()
        }
        .onChange(of: searchText) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.selectedDiscoveredProject) { _, _ in
            cachedLayout = recomputeLayout()
        }
        .onChange(of: viewModel.selectedSkillID) { _, _ in scheduleSelectionSynchronization() }
        .onChange(of: selectedSkillIDs) { _, ids in
            skillUpdateStatusMessage = nil
            if !ids.isEmpty {
                selectedWarning = nil
            }
            // The view model tracks a single focused skill (toolbar title,
            // cross-view state); a multi-selection has no single focus.
            let primary: SkillRecord.ID? = ids.count == 1 ? ids.first : nil
            if viewModel.selectedSkillID != primary {
                viewModel.selectedSkillID = primary
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewSkillRequested)) { _ in
            createNewSkill()
        }
    }

    private var skillsScreenWithSheets: some View {
        skillsScreenCore
        .sheet(isPresented: $isImportSheetPresented) {
            SkillImportSheet(viewModel: viewModel, isPresented: $isImportSheetPresented) { result in
                importSummaryMessage = importSummary(for: result)
            }
        }
        .sheet(item: $skillEditTarget) { target in
            MarkdownFileEditorSheet(target: target) {
                // For a new skill, schedule selection by file path and let the
                // async refresh handle it once the snapshot lands. For an edit
                // of an existing skill the selection already points at it —
                // just kick a background reconciliation. Replaces the prior
                // synchronous refresh that froze the UI on the filesystem scan.
                if target.isNew {
                    viewModel.scheduleSelectSkill(byFilePath: target.path)
                } else {
                    viewModel.refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
                }
            }
        }
        .sheet(item: $newSkillDraft) { draft in
            NewSkillEditorSheet(draft: draft, destinationPath: viewModel.newLibrarySkillPath(for: draft.name.isEmpty ? "skill-name" : draft.name)) { savedDraft in
                try viewModel.saveNewLibrarySkill(savedDraft)
                let savedPath = viewModel.newLibrarySkillPath(for: savedDraft.name)
                viewModel.scheduleSelectSkill(byFilePath: savedPath)
            }
        }
        .sheet(item: $skillPendingRename) { skill in
            RenameResourceSheet(
                title: "Rename Skill",
                currentName: skill.name,
                resourceLabel: "skill",
                makePreview: { viewModel.renamePreview(for: skill, to: $0) },
                onRename: { try viewModel.renameSkill(skill, to: $0) }
            )
        }
        .sheet(item: $skillUpdateConflict) { conflict in
            SkillUpdateConflictSheet(
                viewModel: viewModel,
                context: conflict,
                isPresented: Binding(
                    get: { skillUpdateConflict != nil },
                    set: { if !$0 { skillUpdateConflict = nil } }
                )
            ) { outcome in
                if case .updated = outcome {
                    skillUpdateStatusMessage = "Updated to the latest version."
                }
            }
        }
    }

    @ViewBuilder
    private var skillLibraryContent: some View {
        // Precomputed in AppViewModel, rebuilt only on data rescans — was
        // O(skills × warnings/projects/agents) on every body eval.
        let metadataByID = viewModel.cachedSkillMetadataByID
        let layout = cachedLayout
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.skillReferenceWarnings.isEmpty || !viewModel.skillWarnings.isEmpty {
                skillWarningStrip
            }
            AppList(
                sections: layout.sections,
                selection: .multi($selectedSkillIDs),
                rowTint: { skill in
                    let metadata = metadataByID[skill.id]
                    return (metadata?.hasWarnings ?? false) ? Color.orange.opacity(0.10) : nil
                }
            ) { skill in
                skillListRow(
                    skill,
                    metadata: metadataByID[skill.id] ?? SkillListMetadata(isAssigned: false, hasWarnings: false, isActiveForCurrentProject: false),
                    inactive: layout.inactiveByID[skill.id]
                )
            }
        }
    }

    /// Standalone warnings strip rendered above the AppList. Non-selectable
    /// cards that open detail popovers when tapped — kept outside the list
    /// because `AppList` rows are typed to a single `Item` and warnings are a
    /// different shape than skills.
    @ViewBuilder
    private var skillWarningStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WARNINGS")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.orange)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.skillReferenceWarnings) { warning in
                    skillWarningCard(warning)
                        .padding(.horizontal, 8)
                }
                ForEach(viewModel.skillWarnings) { warning in
                    diagnosticWarningCard(warning)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Builds the cached layout: dedupes + sorts + search-filters the skill
    /// list, then partitions it into the sections the list renders, plus
    /// per-agent `inactiveByID` lookups. Called only from `.onAppear` /
    /// `.onChange` paths via `cachedLayout` — never per body eval.
    /// Mirrors the pattern in `AgentLibraryPane.recomputeLayout()`.
    private func recomputeLayout() -> (
        sections: [AppListSection<SkillRecord>],
        inactiveByID: [SkillRecord.ID: Bool],
        managedSkills: [SkillRecord]
    ) {
        let metadataByID = viewModel.cachedSkillMetadataByID
        let allRecords = viewModel.allVisibleSkillRecords
        let project = selectedProject

        let grouped = Dictionary(grouping: allRecords, by: \.name)
        let preferred = grouped.values.compactMap(preferredSkillRecord)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let managed: [SkillRecord]
        if query.isEmpty {
            managed = preferred
        } else {
            managed = preferred.filter { skill in
                let repository = viewModel.importedRepository(for: skill)
                return [
                    skill.name,
                    skill.description ?? "",
                    skill.source.kind.rawValue,
                    skill.filePath,
                    skill.body,
                    repository?.displayName ?? "",
                    repository.map { "\($0.owner)/\($0.repo)" } ?? ""
                ]
                .contains { $0.lowercased().contains(query) }
            }
        }

        // Same fallback as the previous body-time `skillIsActiveForCurrentProject`
        // — covers the pre-first-scan window where `cachedSkillMetadataByID`
        // hasn't been populated yet.
        func isActiveForCurrentProject(_ skill: SkillRecord) -> Bool {
            if let cached = metadataByID[skill.id] {
                return cached.isActiveForCurrentProject
            }
            if viewModel.skillIsEnabledGlobally(skill) { return true }
            if let project, viewModel.skill(skill, isEnabledFor: project) { return true }
            return false
        }

        var sections: [AppListSection<SkillRecord>] = []
        var inactiveByID: [SkillRecord.ID: Bool] = [:]

        func mark(_ items: [SkillRecord], inactive: Bool) {
            for item in items { inactiveByID[item.id] = inactive }
        }

        if project != nil {
            let active = managed.filter { isActiveForCurrentProject($0) }
            let catalog = managed.filter { !isActiveForCurrentProject($0) }
            mark(active, inactive: false)
            sections.append(AppListSection(
                id: "active",
                title: "Active",
                items: active,
                emptyMessage: "No skills are assigned for this project."
            ))
            if !catalog.isEmpty {
                mark(catalog, inactive: true)
                sections.append(AppListSection(
                    id: "catalog",
                    title: "Catalog",
                    info: "Available skills. They are not injected until made Default, assigned to a project runtime, or assigned to a Deck agent.",
                    items: catalog
                ))
            }
        } else {
            let global = managed.filter { viewModel.skillIsEnabledGlobally($0) }
            let catalog = managed.filter { !isActiveForCurrentProject($0) }
            mark(global, inactive: false)
            sections.append(AppListSection(
                id: "global",
                title: "Default Skills",
                info: "Injected into every parent Pi Agent session. This is global runtime injection, not per-project assignment.",
                items: global,
                emptyMessage: "No default skills."
            ))
            if !catalog.isEmpty {
                mark(catalog, inactive: true)
                sections.append(AppListSection(
                    id: "catalog",
                    title: "Catalog",
                    info: "Available skills. They are not injected until made Default, assigned to a project runtime, or assigned to a Deck agent.",
                    items: catalog
                ))
            }
        }

        return (sections, inactiveByID, managed)
    }

    /// Selection-aware list context menu. A single right-clicked skill gets the
    /// full action set; a multi-selection gets a batch delete.
    @ViewBuilder
    private func skillContextMenu(for ids: Set<SkillRecord.ID>) -> some View {
        let skills = managedSkills.filter { ids.contains($0.id) }
        if skills.count > 1 {
            let importable = skills.filter { viewModel.isImportedSkill($0) }
            let deletable = skills.filter { viewModel.canDeleteSkill($0) }
            if !importable.isEmpty {
                Button {
                    skillsPendingBatchRemoval = importable
                } label: {
                    Label("Remove \(importable.count) from Catalog", systemImage: "minus.circle")
                }
            }
            if !deletable.isEmpty {
                Button(role: .destructive) {
                    skillsPendingBatchDeletion = deletable
                } label: {
                    Label("Delete \(deletable.count) Skill\(deletable.count == 1 ? "" : "s")", systemImage: "trash")
                }
            }
        } else if let skill = skills.first {
            Button {
                skillEditTarget = makeSkillEditTarget(skill)
            } label: {
                Label("Edit SKILL.md", systemImage: "square.and.pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            Button {
                revealSkillInFinder(skill)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }

            Button {
                skillPendingRename = skill
            } label: {
                Label("Rename Skill", systemImage: "pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            if skill.source.kind == .builtin {
                Divider()
                if viewModel.bundledSkillIsDisabled(skill) {
                    Button {
                        viewModel.setBundledSkillDisabled(false, for: skill)
                    } label: {
                        Label("Enable Skill", systemImage: "checkmark.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        viewModel.setBundledSkillDisabled(true, for: skill)
                    } label: {
                        Label("Disable Skill", systemImage: "nosign")
                    }
                }
            }

            if viewModel.isImportedSkill(skill) || viewModel.canDeleteSkill(skill) {
                Divider()
            }

            if viewModel.isImportedSkill(skill) {
                Button {
                    skillPendingRemoval = skill
                } label: {
                    Label("Remove from Catalog", systemImage: "minus.circle")
                }
            }

            if viewModel.canDeleteSkill(skill) {
                Button(role: .destructive) {
                    skillPendingDeletion = skill
                } label: {
                    Label("Delete Skill", systemImage: "trash")
                }
            }
        }
    }

    private func skillWarningCard(_ warning: SkillReferenceWarning) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.missingSkill)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .lineLimit(1)
                Text("Referenced by \(warning.agentName) in \(warning.project.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                selectMissingSkillWarning(warning)
            } label: {
                Text("Resolve")
                    .font(.caption.weight(.semibold))
            }
            .appSmallSecondaryButton()
            .tint(.orange)
            .help("Resolve missing skill")
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            selectMissingSkillWarning(warning)
        }
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    private func selectMissingSkillWarning(_ warning: SkillReferenceWarning) {
        selectedSkillIDs = []
        selectedWarning = .missing(warning)
    }

    private func diagnosticWarningCard(_ warning: DiagnosticWarning) -> some View {
        Button {
            selectedSkillIDs = []
            selectedWarning = .diagnostic(warning)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                Text(warning.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let selectedWarning {
            skillWarningDetail(selectedWarning)
        } else if selectedSkillIDs.count > 1 {
            batchSelectionDetail(selectedSkills)
        } else if let skill = selectedSkill {
            let warnings = warningsForSkill(skill)
            if !warnings.isEmpty {
                skillWarningSummaryCard(warnings: warnings)
            }

            AppCard {
                skillHeaderEditor(skill)

                let rows = skillMetadataRows(skill)
                if !rows.isEmpty {
                    AppKeyValueList(rows: rows)
                }

                detailSummaryBlock(for: skill)
            }

            syncedRepositoryCard(for: skill)

            AppCard(title: "Project Runtime Assignment") {
                projectAssignmentList(for: skill)
            }

            AppCard(title: "Deck Agent Runtime Assignment") {
                agentAssignmentList(for: skill)
            }

            LazyMarkdownCard(
                title: "Definition",
                source: skill.body,
                minimumHeight: 220,
                trailing: {
                    if viewModel.canRenameSkill(skill) {
                        Button {
                            skillEditTarget = makeSkillEditTarget(skill)
                        } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .appSmallSecondaryButton()
                        .help("Edit SKILL.md")
                    }
                }
            )

            if skill.source.kind == .package {
                AppCard(title: "Package Skill") {
                    Text("This skill is provided by an installed package. It is not injected unless assigned as Default, assigned to a project, or assigned to an agent.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if skill.source.kind == .builtin {
                AppCard(title: "Disable Skill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.bundledSkillIsDisabled(skill)
                             ? "Re-enable this built-in skill so it appears in the composer's `/` menu and can be assigned as a Default."
                             : "Turn this built-in skill off everywhere so it does not appear in the composer's `/` menu or get auto-assigned.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.bundledSkillIsDisabled(skill) {
                            Button("Enable Skill") {
                                viewModel.setBundledSkillDisabled(false, for: skill)
                            }
                            .appSecondaryButton()
                        } else {
                            Button("Disable Skill", role: .destructive) {
                                viewModel.setBundledSkillDisabled(true, for: skill)
                            }
                            .appDestructiveButton()
                        }
                    }
                }
            }

            if viewModel.isImportedSkill(skill) {
                AppCard(title: "Remove Skill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Remove this skill from the \(AppBrand.displayName) catalog and clear its Default, project, and agent assignments. The skill files are not deleted.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Remove from Catalog") {
                            skillPendingRemoval = skill
                        }
                        .appSecondaryButton()
                    }
                }
            }

            if skill.source.kind != .builtin && viewModel.canDeleteSkill(skill) {
                AppCard(title: "Delete Skill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Move this skill's file to the Trash and remove its Default, project, and agent assignments.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Delete Skill", role: .destructive) {
                            skillPendingDeletion = skill
                        }
                        .appDestructiveButton()
                    }
                }
            }
        } else {
            AppCard {
                ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    @ViewBuilder
    private func syncedRepositoryCard(for skill: SkillRecord) -> some View {
        if let repository = viewModel.importedRepository(for: skill) {
            AppCard(title: "Synced Repository") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This skill is synced from a GitHub repository. You can edit it here; updates fast-forward and ask before overwriting your edits.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    AppKeyValueList(rows: [
                        ("Source", "GitHub · \(repository.displayName)"),
                        ("Branch", repository.ref),
                        ("Synced", "\(shortCommit(repository.lastSyncedCommit)) · \(repository.lastSyncedDate.formatted(date: .abbreviated, time: .shortened))"),
                        ("Last checked", repository.lastCheckedDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    ])

                    if repository.hasKnownUpdate {
                        Label(
                            "Update available — \(shortCommit(repository.lastSyncedCommit)) → \(shortCommit(repository.latestKnownRemoteCommit ?? ""))",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    }

                    if let skillUpdateStatusMessage {
                        Text(skillUpdateStatusMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button {
                            checkSkillRepositoryForUpdate(repository)
                        } label: {
                            if isCheckingSkillUpdate {
                                AppSpinner().controlSize(.small)
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .appSecondaryButton()
                        .disabled(isCheckingSkillUpdate || isUpdatingSkillRepository)

                        if repository.hasKnownUpdate {
                            Button {
                                applySkillRepositoryUpdate(repository)
                            } label: {
                                if isUpdatingSkillRepository {
                                    AppSpinner().controlSize(.small)
                                } else {
                                    Text("Update Skill")
                                }
                            }
                            .appPrimaryButton()
                            .disabled(isCheckingSkillUpdate || isUpdatingSkillRepository)
                        }

                        if let webURL = repository.webURL {
                            Button("Open on GitHub") { NSWorkspace.shared.open(webURL) }
                                .appSecondaryButton()
                        }
                    }
                }
            }
        }
    }

    private func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    private func checkSkillRepositoryForUpdate(_ repository: ImportedSkillRepository) {
        isCheckingSkillUpdate = true
        skillUpdateStatusMessage = nil
        Task {
            do {
                let status = try await viewModel.checkSkillRepositoryForUpdate(repository)
                isCheckingSkillUpdate = false
                if case .upToDate = status {
                    skillUpdateStatusMessage = "Up to date."
                }
            } catch {
                isCheckingSkillUpdate = false
                skillUpdateStatusMessage = error.localizedDescription
            }
        }
    }

    private func applySkillRepositoryUpdate(_ repository: ImportedSkillRepository) {
        isUpdatingSkillRepository = true
        skillUpdateStatusMessage = nil
        Task {
            do {
                let outcome = try await viewModel.updateSkillRepository(repository)
                isUpdatingSkillRepository = false
                switch outcome {
                case .updated:
                    skillUpdateStatusMessage = "Updated to the latest version."
                case .alreadyUpToDate:
                    skillUpdateStatusMessage = "Already up to date."
                case let .conflicts(conflicts):
                    skillUpdateConflict = SkillUpdateConflictContext(repository: repository, conflicts: conflicts)
                }
            } catch {
                isUpdatingSkillRepository = false
                skillUpdateStatusMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func skillWarningDetail(_ selection: SkillWarningSelection) -> some View {
        switch selection {
        case let .missing(warning):
            missingSkillWarningDetail(warning)
        case let .diagnostic(warning):
            diagnosticSkillWarningDetail(warning)
        }
    }

    private func missingSkillWarningDetail(_ warning: SkillReferenceWarning) -> some View {
        let candidate = viewModel.unavailableSkillResolutionCandidate(for: warning)
        return AppCard(title: "Missing Skill") {
            VStack(alignment: .leading, spacing: 14) {
                Text(missingSkillExplanation(for: warning, candidate: candidate))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                AppKeyValueList(rows: missingSkillWarningRows(for: warning, candidate: candidate))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Resolve by doing one of these:")
                        .font(.body.weight(.semibold))
                    if candidate != nil {
                        Text("Move the existing skill into the global skill catalog so every project can resolve the global/library agent reference.")
                    } else {
                        Text("Create, install, or import a skill named `\(warning.missingSkill)` somewhere `\(warning.project.repositoryDisplayName)` can see it.")
                    }
                    Text("Or remove `\(warning.missingSkill)` from `\(warning.agentName)` if the reference is obsolete.")
                }
                .foregroundStyle(AppTheme.mutedText)
                .textSelection(.enabled)

                HStack {
                    if let candidate {
                        Button("Move to Global Skills") {
                            do {
                                try viewModel.moveSkillToGlobalCatalog(candidate)
                                selectedWarning = nil
                            } catch {
                                skillActionErrorMessage = error.localizedDescription
                            }
                        }
                        .appPrimaryButton()
                    }
                    Button("Search Catalog") {
                        searchText = warning.missingSkill
                    }
                    .appSecondaryButton()
                    Button("Import Skills") {
                        beginSkillImport()
                    }
                    .appSecondaryButton()
                    if let agentPath = sourcePath(forAgentNamed: warning.agentName, projectPath: warning.project.path) {
                        Button("Reveal Agent File") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agentPath)])
                        }
                        .appSecondaryButton()
                    }
                }
            }
        }
    }

    private func missingSkillWarningRows(for warning: SkillReferenceWarning, candidate: SkillRecord?) -> [(String, String)] {
        var rows = [
            ("Skill", warning.missingSkill),
            ("Agent", warning.agentName),
            ("Project", warning.project.repositoryDisplayName),
            ("Project Path", warning.project.path)
        ]
        if let candidate {
            rows.append(("Found Elsewhere", candidate.filePath))
        }
        return rows
    }

    private func missingSkillExplanation(for warning: SkillReferenceWarning, candidate: SkillRecord?) -> String {
        if let candidate {
            return "`\(warning.agentName)` references `\(warning.missingSkill)`, but `\(warning.project.repositoryDisplayName)` cannot resolve that skill at runtime. A skill with that name exists elsewhere (`\(candidate.filePath)`), so it is probably scoped to another project or catalog source instead of being globally available."
        }
        return "`\(warning.agentName)` references `\(warning.missingSkill)`, but `\(warning.project.repositoryDisplayName)` cannot resolve a skill with that name at runtime."
    }

    private func diagnosticSkillWarningDetail(_ warning: DiagnosticWarning) -> some View {
        AppCard(title: "Skill Warning") {
            VStack(alignment: .leading, spacing: 14) {
                Text(warning.message)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let duplicate = duplicateSkillWarningDetails(warning) {
                    AppKeyValueList(rows: [
                        ("Skill", duplicate.name),
                        ("Issue", "Duplicate skill name"),
                        ("Locations", duplicate.paths.joined(separator: "\n"))
                    ])

                    Text("Keep one canonical copy of this skill and remove or rename the duplicate. Agent Deck can only pass a skill reliably when the name resolves to one path.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Search Catalog") {
                            searchText = duplicate.name
                        }
                        ForEach(Array(duplicate.paths.enumerated()), id: \.offset) { index, path in
                            Button("Reveal Copy \(index + 1)") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                } else {
                    Text("Review the referenced file or setting, then fix the malformed or conflicting skill definition.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private func skillWarningSummaryCard(warnings: [DiagnosticWarning]) -> some View {
        AppCard(title: "Warnings") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(warnings) { warning in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        Text(warning.message)
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedProject: DiscoveredProject? {
        viewModel.selectedDiscoveredProject
    }

    /// Reads from the `cachedLayout` rebuilt by `recomputeLayout()` on input
    /// changes. Pre-refactor this property did the dedupe + sort + multi-field
    /// search inline on every access — and was hit from `skillListLayout`,
    /// `selectedSkill`, `selectedSkills`, `synchronizeSelectionFromViewModel`,
    /// `skillContextMenu`, and batch-action helpers, several of them inside
    /// the body. Same value, but now O(1).
    private var managedSkills: [SkillRecord] {
        cachedLayout.managedSkills
    }

    /// The skill shown in the detail pane — only when exactly one is selected.
    private var selectedSkill: SkillRecord? {
        guard selectedWarning == nil, selectedSkillIDs.count == 1, let id = selectedSkillIDs.first else { return nil }
        return managedSkills.first { $0.id == id }
    }

    private var selectedSkills: [SkillRecord] {
        managedSkills.filter { selectedSkillIDs.contains($0.id) }
    }

    private var skillDetailTitle: String {
        if selectedSkillIDs.count > 1 { return "\(selectedSkillIDs.count) Skills Selected" }
        return selectedSkill?.name ?? "Skill Details"
    }

    private var skillDetailSubtitle: String? {
        if selectedSkillIDs.count > 1 { return "Batch actions" }
        return selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }
    }

    private var activeSkills: [SkillRecord] {
        if selectedProject != nil {
            return managedSkills.filter { skillIsActiveForCurrentProject($0) }
        }
        return globalSkills
    }

    private var globalSkills: [SkillRecord] {
        managedSkills.filter { viewModel.skillIsEnabledGlobally($0) }
    }

    private var catalogSkills: [SkillRecord] {
        managedSkills.filter { !skillIsActiveForCurrentProject($0) }
    }

    private var projectAssignedSkills: [SkillRecord] {
        guard let selectedProject else { return [] }
        return managedSkills.filter {
            viewModel.skill($0, isEnabledFor: selectedProject) &&
            !viewModel.skillIsEnabledGlobally($0)
        }
    }

    private func preferredSkillRecord(_ records: [SkillRecord]) -> SkillRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .legacyProject }
        ?? records.first
    }

    private func skillIsActiveForCurrentProject(_ skill: SkillRecord) -> Bool {
        // Precomputed in AppViewModel's cachedSkillMetadataByID, rebuilt on
        // data rescans. Live fallback covers the pre-first-scan window.
        if let cached = viewModel.cachedSkillMetadataByID[skill.id] {
            return cached.isActiveForCurrentProject
        }
        if viewModel.skillIsEnabledGlobally(skill) { return true }
        if let selectedProject, viewModel.skill(skill, isEnabledFor: selectedProject) { return true }
        return false
    }

    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        let validIDs = Set(managedSkills.map(\.id))

        // Drop selections that no longer exist after a rescan.
        let pruned = selectedSkillIDs.intersection(validIDs)
        if pruned != selectedSkillIDs {
            selectedSkillIDs = pruned
        }

        // Adopt an external single-skill focus request (import, warning jump)
        // without clobbering a deliberate multi-selection.
        if let viewModelSkillID = viewModel.selectedSkillID, selectedSkillIDs.count <= 1 {
            if validIDs.contains(viewModelSkillID), selectedSkillIDs != [viewModelSkillID] {
                selectedSkillIDs = [viewModelSkillID]
                return
            }
            // The view model may point at a non-preferred duplicate record;
            // re-anchor to the catalog record actually shown in the list.
            if let name = viewModel.allVisibleSkillRecords.first(where: { $0.id == viewModelSkillID })?.name,
               let preferred = managedSkills.first(where: { $0.name == name }),
               selectedSkillIDs != [preferred.id] {
                selectedSkillIDs = [preferred.id]
                return
            }
        }

        ensureSelection()
    }

    private func ensureSelection() {
        guard selectedWarning == nil, selectedSkillIDs.isEmpty else { return }
        if let first = managedSkills.first {
            selectedSkillIDs = [first.id]
        }
    }

    private func skillListRow(_ skill: SkillRecord, metadata: SkillListMetadata, inactive: Bool? = nil) -> some View {
        let isActive = metadata.isAssigned
        let isInactive = inactive ?? !isActive
        let hasWarnings = metadata.hasWarnings
        let iconName = hasWarnings ? "exclamationmark.triangle.fill" : skillIcon(skill)
        let iconColor: Color = hasWarnings ? .orange : skillColor(isAssigned: isActive)
        let repository = viewModel.importedRepository(for: skill)
        let hasUpdate = repository?.hasKnownUpdate == true
        let canRename = viewModel.canRenameSkill(skill)
        return SkillListRowView(
            skill: skill,
            iconName: iconName,
            iconColor: iconColor,
            isInactive: isInactive,
            repositoryDisplayName: repository?.displayName,
            hasUpdate: hasUpdate,
            isUpdating: repository != nil && isUpdatingSkillRepository,
            canRename: canRename,
            onUpdate: repository.map { repository in
                { applySkillRepositoryUpdate(repository) }
            },
            onEdit: { skillEditTarget = makeSkillEditTarget(skill) }
        )
        .contextMenu {
            // Selection-aware: a multi-selection that includes the right-
            // clicked row gets the batch actions; otherwise the right-clicked
            // row gets the single-skill action set. Mirrors the previous
            // `contextMenu(forSelectionType:)` semantics one-for-one.
            let effectiveIDs: Set<SkillRecord.ID> = (selectedSkillIDs.count > 1 && selectedSkillIDs.contains(skill.id))
                ? selectedSkillIDs
                : [skill.id]
            skillContextMenu(for: effectiveIDs)
        }
    }

    private func projectAssignmentList(for skill: SkillRecord) -> some View {
        let isGlobal = viewModel.skillIsEnabledGlobally(skill)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Enable this skill for every project at once, or pick specific projects below. Per-project assignments are preserved when you toggle All Projects.")
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            LazyVStack(alignment: .leading, spacing: 0) {
                AllProjectsAssignmentRow(
                    isOn: Binding(
                        get: { isGlobal },
                        set: { enabled in
                            do {
                                if enabled {
                                    try viewModel.enableSkillGlobally(skill)
                                } else {
                                    try viewModel.disableSkillGlobally(skill)
                                }
                            } catch {
                                presentSkillActionError(error, skill: skill, action: enabled ? "enable global visibility" : "disable global visibility")
                            }
                        }
                    ),
                    subtitle: "Enable this skill for every project"
                )
                Divider()
                ForEach(viewModel.enabledProjects) { project in
                    ProjectAssignmentToggleRow(
                        project: project,
                        isOn: Binding(
                            get: { isGlobal ? true : viewModel.skill(skill, isEnabledFor: project) },
                            set: { enabled in
                                do { try viewModel.setSkill(skill, enabled: enabled, for: project) }
                                catch { presentSkillActionError(error, skill: skill, project: project, action: enabled ? "assign this skill" : "remove this skill assignment") }
                            }
                        )
                    )
                    .opacity(isGlobal ? 0.4 : 1)
                    .allowsHitTesting(!isGlobal)

                    if project.id != viewModel.enabledProjects.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func agentAssignmentList(for skill: SkillRecord) -> some View {
        SkillAgentAssignmentList(
            skill: skill,
            viewModel: viewModel,
            presentError: { error, action in
                presentSkillActionError(error, skill: skill, action: action)
            }
        )
    }

    private func skillIcon(_ skill: SkillRecord) -> String {
        if skill.source.kind == .builtin { return "shippingbox" }
        return "wand.and.stars"
    }

    private func skillColor(isAssigned: Bool) -> Color {
        if isAssigned { return AppTheme.sourceProject }
        return AppTheme.mutedText
    }

    /// Reads from `viewModel.cachedWarningsBySkillID`, which is populated by
    /// `rebuildWarningCaches()` alongside `cachedSkillMetadataByID.hasWarnings`.
    /// Pre-cache this ran four string-contains checks against every entry in
    /// `skillWarnings` on every skill-detail render.
    private func warningsForSkill(_ skill: SkillRecord) -> [DiagnosticWarning] {
        viewModel.cachedWarningsBySkillID[skill.id] ?? []
    }

    private func duplicateSkillWarningDetails(_ warning: DiagnosticWarning) -> (name: String, paths: [String])? {
        guard warning.id.hasPrefix("duplicate-skill:") else { return nil }
        let name = String(warning.id.dropFirst("duplicate-skill:".count))
        guard let range = warning.message.range(of: " found at: ") else {
            return (name, [])
        }
        let paths = warning.message[range.upperBound...]
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (name, paths)
    }

    private func sourcePath(forAgentNamed agentName: String, projectPath: String) -> String? {
        viewModel.snapshot.effectiveAgents.first {
            $0.name == agentName && ($0.projectRoot == projectPath || $0.projectRoot == nil)
        }?.sourcePath
    }

    @ViewBuilder
    private func skillHeaderEditor(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                skillNameEditableView(skill)
                Spacer(minLength: 12)
                if viewModel.skillDescriptionGenerationModel() != nil {
                    detailMagicButton(for: skill)
                }
            }
            if let skillRenameErrorMessage {
                Text(skillRenameErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
        .onChange(of: skill.id) { _, _ in
            cancelSkillRename(for: skill)
        }
    }

    @ViewBuilder
    private func detailSummaryBlock(for skill: SkillRecord) -> some View {
        if let state = detailSummariesBySkillID[skill.id] {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                switch state {
                case .loading:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Summary")
                            .font(.caption.weight(.semibold))
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Summarising with AI…")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                case let .ready(text):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Summary")
                            .font(.caption.weight(.semibold))
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        MarkdownDocumentView(source: text, minimumHeight: 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Summary")
                            .font(.caption.weight(.semibold))
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailMagicButton(for skill: SkillRecord) -> some View {
        let state = detailSummariesBySkillID[skill.id]
        AppCircleIconButton(
            style: .soft,
            tint: AppTheme.brandAccent,
            size: 28,
            imageScale: .medium,
            help: detailMagicButtonHelpText(for: state),
            action: { Task { await requestDetailSummary(for: skill) } }
        ) {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "arrow.clockwise")
            default:
                Image(systemName: "sparkles")
            }
        }
        .disabled(state == .loading)
    }

    private func detailMagicButtonHelpText(for state: SkillDetailSummaryState?) -> String {
        switch state {
        case .loading: return "Generating summary…"
        case .failed: return "Retry AI summary"
        case .ready: return "Regenerate AI summary"
        case .none: return "Summarise this skill with AI"
        }
    }

    private func requestDetailSummary(for skill: SkillRecord) async {
        detailSummariesBySkillID[skill.id] = .loading
        do {
            let summary = try await viewModel.generateSkillDescription(skillContent: skill.body)
            detailSummariesBySkillID[skill.id] = .ready(summary)
        } catch {
            detailSummariesBySkillID[skill.id] = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func skillNameEditableView(_ skill: SkillRecord) -> some View {
        if isRenamingSkillName {
            TextField("Skill name", text: $draftSkillName)
                .textFieldStyle(.plain)
                .font(.body.weight(.semibold))
                .fontWidth(.expanded)
                .focused($isSkillNameFocused)
                .onSubmit { commitSkillRename(for: skill) }
                .onExitCommand { cancelSkillRename(for: skill) }
                .onAppear {
                    draftSkillName = skill.name
                    isSkillNameFocused = true
                }
        } else {
            HStack(alignment: .center, spacing: 6) {
                Text(skill.name)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
                if viewModel.canRenameSkill(skill) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .opacity(isSkillNameHovered ? 0.85 : 0)
                }
            }
            .contentShape(Rectangle())
            .onHover { isSkillNameHovered = $0 }
            .onTapGesture { beginSkillRename(for: skill) }
            .help(viewModel.canRenameSkill(skill) ? "Rename skill" : "")
        }
    }

    private func beginSkillRename(for skill: SkillRecord) {
        guard viewModel.canRenameSkill(skill), !isRenamingSkillName else { return }
        skillRenameErrorMessage = nil
        draftSkillName = skill.name
        isRenamingSkillName = true
        isSkillNameFocused = true
    }

    private func cancelSkillRename(for skill: SkillRecord) {
        isRenamingSkillName = false
        isSkillNameFocused = false
        draftSkillName = skill.name
        skillRenameErrorMessage = nil
    }

    private func commitSkillRename(for skill: SkillRecord) {
        let trimmed = draftSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelSkillRename(for: skill)
            return
        }
        guard trimmed != skill.name else {
            cancelSkillRename(for: skill)
            return
        }
        do {
            try viewModel.renameSkill(skill, to: trimmed)
            isRenamingSkillName = false
            isSkillNameFocused = false
            skillRenameErrorMessage = nil
        } catch {
            skillRenameErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func skillMetadataRows(_ skill: SkillRecord) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !skill.filePath.isEmpty {
            rows.append(("File", skill.filePath))
        }
        return rows
    }

    private func assignedProjectSummary(_ skill: SkillRecord) -> String {
        let projects = viewModel.assignedProjects(for: skill).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

    private func assignedAgentSummary(_ skill: SkillRecord) -> String {
        let agents = viewModel.assignedAgents(for: skill).map(\.name)
        return agents.isEmpty ? "—" : agents.joined(separator: ", ")
    }

    private func revealSkillInFinder(_ skill: SkillRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.filePath)])
    }

    private func deleteSkill(_ skill: SkillRecord) {
        do {
            try viewModel.deleteSkill(skill)
            skillPendingDeletion = nil
        } catch {
            skillPendingDeletion = nil
            presentSkillActionError(error, skill: skill, action: "delete this skill")
        }
    }

    private func batchDeleteSkills(_ skills: [SkillRecord]) {
        // Single refresh after the loop — `deleteSkills` does the filesystem
        // work per skill but only triggers one background rescan at the end.
        let failed = viewModel.deleteSkills(skills)
        skillsPendingBatchDeletion = nil
        selectedSkillIDs = []
        if !failed.isEmpty {
            NSSound.beep()
            skillActionErrorMessage = """
            \(AppBrand.displayName) could not delete \(failed.count) skill\(failed.count == 1 ? "" : "s"): \(failed.joined(separator: ", ")).

            Bundled and package skills cannot be deleted.
            """
        }
    }

    private func removeSkill(_ skill: SkillRecord) {
        do {
            try viewModel.removeSkillFromCatalog(skill)
            skillPendingRemoval = nil
        } catch {
            skillPendingRemoval = nil
            presentSkillActionError(error, skill: skill, action: "remove this skill from the catalog")
        }
    }

    private func batchRemoveSkills(_ skills: [SkillRecord]) {
        // Single refresh after the loop — `removeSkillsFromCatalog` does the
        // filesystem work per skill but only triggers one background rescan.
        let failed = viewModel.removeSkillsFromCatalog(skills)
        skillsPendingBatchRemoval = nil
        selectedSkillIDs = []
        if !failed.isEmpty {
            NSSound.beep()
            skillActionErrorMessage = """
            \(AppBrand.displayName) could not remove \(failed.count) skill\(failed.count == 1 ? "" : "s"): \(failed.joined(separator: ", ")).

            Only imported skills can be removed from the catalog.
            """
        }
    }

    @ViewBuilder
    private func batchSelectionDetail(_ skills: [SkillRecord]) -> some View {
        let deletable = skills.filter { viewModel.canDeleteSkill($0) }
        let importable = skills.filter { viewModel.isImportedSkill($0) }
        AppCard(title: "\(skills.count) Skills Selected") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cmd- or Shift-click rows to adjust the selection. Right-click the list — or use the button below — to act on every selected skill at once.")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skills, id: \.id) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: skillIcon(skill))
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 18)
                            Text(skill.name)
                                .font(.callout.weight(.medium))
                            if !viewModel.canDeleteSkill(skill) {
                                Text("Protected")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                HStack(spacing: 10) {
                    if !importable.isEmpty {
                        Button("Remove \(importable.count) from Catalog…") {
                            skillsPendingBatchRemoval = importable
                        }
                        .appSecondaryButton()
                    }

                    Button("Delete \(deletable.count) Skill\(deletable.count == 1 ? "" : "s")…") {
                        skillsPendingBatchDeletion = deletable
                    }
                    .appDestructiveButton()
                    .disabled(deletable.isEmpty)
                }

                if !importable.isEmpty {
                    Text("Remove un-imports a skill (its files and any Git clone are kept). Delete moves the skill folder to the Trash.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if deletable.count != skills.count {
                    Text("Bundled and package skills are protected and will not be deleted.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private func makeSkillEditTarget(_ skill: SkillRecord) -> MarkdownFileEditTarget {
        MarkdownFileEditTarget(
            title: "Edit \(skill.name)",
            path: skill.filePath,
            note: "Editing the raw SKILL.md. Changes apply after you save."
        )
    }

    private func createNewSkill() {
        newSkillDraft = viewModel.makeNewLibrarySkillDraft()
    }

    private func beginSkillImport() {
        isImportSheetPresented = true
    }

    private func importSummary(for result: SkillImportResult) -> String {
        var parts: [String] = []
        if !result.importedNames.isEmpty {
            parts.append("Imported \(result.importedNames.count) skill\(result.importedNames.count == 1 ? "" : "s"): \(result.importedNames.joined(separator: ", ")).")
        }
        if !result.skippedNames.isEmpty {
            parts.append("Skipped \(result.skippedNames.count) existing skill\(result.skippedNames.count == 1 ? "" : "s"): \(result.skippedNames.joined(separator: ", ")).")
        }
        return parts.isEmpty ? "No skills were imported." : parts.joined(separator: "\n\n")
    }

    private func presentSkillActionError(_ error: Error, skill: SkillRecord, project: DiscoveredProject? = nil, action: String) {
        NSSound.beep()
        let target = project.map { "project \($0.name)" } ?? "global skills"
        let conflictPath = project.map { "\($0.path)/.pi/skills/\(skill.name)" } ?? "~/.pi/agent/skills/\(skill.name)"
        skillActionErrorMessage = """
        \(AppBrand.displayName) could not \(action) for "\(skill.name)" in \(target).

        If a skill with this name already exists at \(conflictPath), \(AppBrand.displayName) will not overwrite it automatically. Remove or rename the existing skill, then try again.

        \(error.localizedDescription)
        """
    }

}

private struct AgentAssignmentToggleRow: View {
    let agent: EffectiveAgentRecord
    let imageURL: URL?
    let isInactive: Bool
    @Binding var isOn: Bool

    /// Optimistic value held from a tap until the async snapshot refresh makes
    /// the external `isOn` catch up. Without it the checkbox visibly snaps back
    /// after each tap, because skill→agent assignment now reconciles in the
    /// background instead of via a blocking rescan.
    @State private var optimisticValue: Bool?

    private var displayedIsOn: Bool { optimisticValue ?? isOn }

    var body: some View {
        let toggleBinding = Binding(
            get: { displayedIsOn },
            set: { newValue in
                optimisticValue = newValue
                isOn = newValue
            }
        )

        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: toggleBinding)
                .appCheckbox()
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)
                // Visual indicator only; the row's `.onTapGesture` is the sole
                // tap handler. Letting the checkbox also handle clicks fires
                // the toggle twice when the box itself is clicked.
                .allowsHitTesting(false)

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(agentIconFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(displayedIsOn ? AppTheme.accentSelectionStroke : AppTheme.contentStroke, lineWidth: 1)
                    }

                if let nsImage = AgentImageLoader.image(at: imageURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: SidebarItem.agents.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(displayedIsOn ? AppTheme.accentForeground : AppTheme.mutedText)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.body.weight(.semibold))
                Text(agentSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleBinding.wrappedValue.toggle()
        }
        .onChange(of: isOn) { _, _ in
            // External state has caught up — drop the optimistic override so
            // the snapshot value is authoritative again.
            optimisticValue = nil
        }
    }

    private var agentIconFill: LinearGradient {
        LinearGradient(
            colors: displayedIsOn
                ? [AppTheme.brandAccentBright, AppTheme.brandAccent]
                : [AppTheme.contentFill, AppTheme.contentSubtleFill],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var agentSubtitle: String {
        let whenToUse = agent.resolved.whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whenToUse, !whenToUse.isEmpty {
            return whenToUse
        }

        let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "No routing guidance set." : description
    }
}

/// Subagent assignment card body for the skill detail pane. Owns the sorted
/// active/inactive agent arrays in local `@State` so the sort + Set
/// construction runs only when the snapshot or selected skill actually
/// changes, not on every detail-pane render. Pre-extraction these were
/// inline `let`s inside a body-eval'd function — sorting every time the
/// detail re-rendered (e.g. on every selection click or `cachedLayout`
/// update).
private struct SkillAgentAssignmentList: View {
    let skill: SkillRecord
    let viewModel: AppViewModel
    let presentError: (Error, String) -> Void

    @State private var activeAgents: [EffectiveAgentRecord] = []
    @State private var inactiveAgents: [EffectiveAgentRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign this skill only to the selected Deck agents when they run. Parent Pi Agent sessions do not receive it from this setting.")
                .foregroundStyle(AppTheme.mutedText)

            VStack(alignment: .leading, spacing: 14) {
                SkillAgentAssignmentSection(
                    title: "Active",
                    agents: activeAgents,
                    skill: skill,
                    viewModel: viewModel,
                    presentError: presentError,
                    isInactiveSection: false,
                    emptyText: "No active Deck agents."
                )

                if !inactiveAgents.isEmpty {
                    SkillAgentAssignmentSection(
                        title: "Inactive",
                        agents: inactiveAgents,
                        skill: skill,
                        viewModel: viewModel,
                        presentError: presentError,
                        isInactiveSection: true,
                        emptyText: "No inactive Deck agents."
                    )
                }
            }
        }
        .onAppear { recompute() }
        .onChange(of: skill.id) { _, _ in recompute() }
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in recompute() }
    }

    private func recompute() {
        let active = viewModel.snapshot.effectiveAgents
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let activeIDs = Set(active.map(\.id))
        let inactive = viewModel.allDisplayAgents
            .filter { !activeIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeAgents = active
        inactiveAgents = inactive
    }
}

private struct SkillAgentAssignmentSection: View {
    let title: String
    let agents: [EffectiveAgentRecord]
    let skill: SkillRecord
    let viewModel: AppViewModel
    let presentError: (Error, String) -> Void
    let isInactiveSection: Bool
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)

            if agents.isEmpty {
                nativeEmptyRow(emptyText)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(agents) { agent in
                        AgentAssignmentToggleRow(
                            agent: agent,
                            imageURL: viewModel.agentImageStore.imageURL(for: agent.name),
                            isInactive: isInactiveSection,
                            isOn: Binding(
                                get: { viewModel.skill(skill, isAssignedTo: agent) },
                                set: { enabled in
                                    do { try viewModel.setSkill(skill, enabled: enabled, for: agent) }
                                    catch { presentError(error, enabled ? "assign this skill to agent" : "remove this skill from agent") }
                                }
                            )
                        )

                        if agent.id != agents.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// Skill catalog row. Owns its own hover `@State` so a hover on row A only
/// invalidates row A — pre-extraction the parent owned a `hoveredSkillID`
/// and every visible row had to re-evaluate `hoveredSkillID == skill.id`
/// when any row was hovered, animating opacity changes across the whole list.
private struct SkillListRowView: View {
    let skill: SkillRecord
    let iconName: String
    let iconColor: Color
    let isInactive: Bool
    let repositoryDisplayName: String?
    let hasUpdate: Bool
    let isUpdating: Bool
    let canRename: Bool
    let onUpdate: (() -> Void)?
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(skill.description ?? "No description")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let repositoryDisplayName {
                    HStack(spacing: 6) {
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 11, height: 11)
                        Text(repositoryDisplayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .help("Synced from GitHub · \(repositoryDisplayName)")
                }
            }

            Spacer(minLength: 0)

            if let onUpdate {
                Button(action: onUpdate) {
                    if isUpdating {
                        AppSpinner().controlSize(.small)
                    } else {
                        Text("Update")
                            .font(.caption.weight(.semibold))
                    }
                }
                .appSmallSecondaryButton()
                .opacity(isHovered ? 1 : 0)
                .disabled(isUpdating)
                .help(hasUpdate ? "Update available — sync this skill from GitHub" : "Sync this skill from GitHub")
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }

            if canRename {
                Button(action: onEdit) {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .appSmallSecondaryButton()
                .opacity(isHovered ? 1 : 0)
                .help("Edit SKILL.md")
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.vertical, 5)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
    }
}
