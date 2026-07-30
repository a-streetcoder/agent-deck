import AppKit
import OSLog
import SwiftUI

struct SkillsInfoPopover: View {
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(languageStore.t("skills.assignmentTitle"))
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow(languageStore.t("skills.infoCatalogTitle"), languageStore.t("skills.infoCatalogBody"))
                infoRow(languageStore.t("skills.infoDefaultTitle"), languageStore.t("skills.infoDefaultBody"))
                infoRow(languageStore.t("skills.infoProjectTitle"), languageStore.t("skills.infoProjectBody"))
                infoRow(languageStore.t("skills.infoAgentsTitle"), languageStore.t("skills.infoAgentsBody"))
            }

            Text(languageStore.t("skills.infoFooter"))
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

private enum SkillLibraryItem: Identifiable, Hashable {
    case collection(SkillCollectionRecord)
    case skill(SkillRecord)

    var id: String {
        switch self {
        case let .collection(collection): return "collection:\(collection.id.uuidString)"
        case let .skill(skill): return "skill:\(skill.id)"
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
        case .diagnostic: return LanguageStore.shared.t("skills.warningTitle")
        }
    }

    var subtitle: String {
        switch self {
        case let .missing(warning): return LanguageStore.shared.t("skills.referencedBy", warning.agentName, warning.project.name)
        case .diagnostic: return LanguageStore.shared.t("skills.catalogIssue")
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
    /// Whether the skill's root path is tracked in `externalSkillPaths`.
    /// `isImportedSkill(_:)` resolves `URL.standardizedFileURL` (lstat) per
    /// call, so the context-menu builder — which SwiftUI re-evaluates during
    /// layout for every visible row — must read this cached flag instead of
    /// the live method, otherwise scrolling the skills list stalls the main
    /// thread with stat syscalls.
    let isImported: Bool

    func isVisuallyActive(isCollectionMember: Bool) -> Bool {
        isAssigned || isCollectionMember
    }
}

private enum SkillDetailSummaryState: Equatable {
    case loading
    case ready(String)
    case failed(String)
}

struct SkillsScreen: View {
    private static let layoutLog = Logger(subsystem: "works.earendil.pi-deck", category: "ResourceLayout")
    var viewModel: AppViewModel
    @Binding var searchText: String
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var selectedLibraryItemIDs: Set<SkillLibraryItem.ID> = []
    @State private var selectedSkillIDs: Set<SkillRecord.ID> = []
    @State private var selectedCollectionID: UUID?
    @State private var skillsPendingBatchDeletion: [SkillRecord]?
    @State private var collectionPendingDeletion: SkillCollectionRecord?
    @State private var selectedWarning: SkillWarningSelection?
    @State private var isImportSheetPresented = false
    @State private var isCollectionSheetPresented = false
    @State private var importSummaryMessage: String?
    @State private var skillActionErrorMessage: String?
    @State private var skillPendingDeletion: SkillRecord?
    @State private var skillPendingRemoval: SkillRecord?
    @State private var skillsPendingBatchRemoval: [SkillRecord]?
    @State private var skillPendingDuplicateResolution: (kept: SkillRecord, removed: [SkillRecord])?
    @State private var hoveredWarningID: String?
    @State private var skillCompareContext: SkillCompareContext?
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
    @State private var readOnlySkillPreview: SkillRecord?
    // Cached sectioning + filtered list + per-row inactive map. The full
    // build runs `Dictionary(grouping:)` + sort + multi-field search +
    // sectioning over `viewModel.allVisibleSkillRecords` — recomputing it on
    // every body eval (every selection click, hover, scroll) was the
    // dominant cost. Recompute only when an actual input changes
    // (snapshot, search, project, metadata revision). Mirrors the pattern
    // in `AgentLibraryPane`.
    @State private var cachedLayout: (
        sections: [AppListSection<SkillLibraryItem>],
        inactiveByID: [SkillRecord.ID: Bool],
        managedSkills: [SkillRecord],
        catalogSkills: [SkillRecord],
        repositoryBySkillID: [SkillRecord.ID: ImportedSkillRepository],
        collectionCountBySkillID: [SkillRecord.ID: Int],
        collectionMembersByID: [UUID: [SkillRecord]]
    ) = ([], [:], [], [], [:], [:], [:])

    var body: some View {
        skillsScreenWithSheets
            .alert(LanguageStore.shared.t("skills.alert.import"), isPresented: Binding(
                get: { importSummaryMessage != nil },
                set: { if !$0 { importSummaryMessage = nil } }
            )) {
                Button(LanguageStore.shared.t("common.ok")) { importSummaryMessage = nil }
            } message: {
                Text(importSummaryMessage ?? "")
            }
            .alert(LanguageStore.shared.t("skills.alert.assignment"), isPresented: Binding(
                get: { skillActionErrorMessage != nil },
                set: { if !$0 { skillActionErrorMessage = nil } }
            )) {
                Button(LanguageStore.shared.t("common.ok")) { skillActionErrorMessage = nil }
            } message: {
                Text(skillActionErrorMessage ?? "")
            }
            .alert(LanguageStore.shared.t("skills.alert.delete"), isPresented: Binding(
                get: { skillPendingDeletion != nil },
                set: { if !$0 { skillPendingDeletion = nil } }
            ), presenting: skillPendingDeletion) { skill in
                Button(LanguageStore.shared.t("skills.moveTrash"), role: .destructive) { deleteSkill(skill) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { skillPendingDeletion = nil }
            } message: { skill in
                Text(LanguageStore.shared.t("skills.alert.deleteMessage", skill.name))
            }
            .alert(LanguageStore.shared.t("skills.alert.deleteMany"), isPresented: Binding(
                get: { skillsPendingBatchDeletion != nil },
                set: { if !$0 { skillsPendingBatchDeletion = nil } }
            ), presenting: skillsPendingBatchDeletion) { skills in
                Button(LanguageStore.shared.t("skills.alert.moveManyTrash", skills.count), role: .destructive) { batchDeleteSkills(skills) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { skillsPendingBatchDeletion = nil }
            } message: { skills in
                Text(LanguageStore.shared.t("skills.alert.deleteManyMessage", skills.count))
            }
            .alert(LanguageStore.shared.t("skills.alert.deleteCollection"), isPresented: Binding(
                get: { collectionPendingDeletion != nil },
                set: { if !$0 { collectionPendingDeletion = nil } }
            ), presenting: collectionPendingDeletion) { collection in
                Button(LanguageStore.shared.t("skills.deleteCollectionOnly"), role: .destructive) { deleteCollectionOnly(collection) }
                Button(LanguageStore.shared.t("skills.deleteCollectionAndSkills"), role: .destructive) { deleteCollectionAndMembers(collection) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { collectionPendingDeletion = nil }
            } message: { collection in
                let memberCount = cachedLayout.collectionMembersByID[collection.id]?.count ?? 0
                Text(LanguageStore.shared.t("skills.alert.deleteCollectionMessage", collection.name, memberCount))
            }
            .alert(LanguageStore.shared.t("skills.alert.remove"), isPresented: Binding(
                get: { skillPendingRemoval != nil },
                set: { if !$0 { skillPendingRemoval = nil } }
            ), presenting: skillPendingRemoval) { skill in
                Button(LanguageStore.shared.t("skills.removeFromCatalog")) { removeSkill(skill) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { skillPendingRemoval = nil }
            } message: { skill in
                Text(LanguageStore.shared.t("skills.alert.removeMessage", skill.name, AppBrand.displayName))
            }
            .alert(LanguageStore.shared.t("skills.alert.removeMany"), isPresented: Binding(
                get: { skillsPendingBatchRemoval != nil },
                set: { if !$0 { skillsPendingBatchRemoval = nil } }
            ), presenting: skillsPendingBatchRemoval) { skills in
                Button(LanguageStore.shared.t("skills.alert.removeManyAction", skills.count)) { batchRemoveSkills(skills) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { skillsPendingBatchRemoval = nil }
            } message: { skills in
                Text(LanguageStore.shared.t("skills.alert.removeManyMessage", skills.count, AppBrand.displayName))
            }
            .alert(LanguageStore.shared.t("skills.alert.resolveDup"), isPresented: Binding(
                get: { skillPendingDuplicateResolution != nil },
                set: { if !$0 { skillPendingDuplicateResolution = nil } }
            ), presenting: skillPendingDuplicateResolution) { context in
                Button(LanguageStore.shared.t("skills.keepCopy"), role: .destructive) { resolveDuplicateSkill(context) }
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { skillPendingDuplicateResolution = nil }
            } message: { context in
                Text(LanguageStore.shared.t("skills.alert.resolveDupMessage", context.kept.name, context.kept.filePath, context.removed.count))
            }
            .alert(LanguageStore.shared.t("skills.alert.updates"), isPresented: Binding(
                get: { viewModel.skillBatchActionMessage != nil },
                set: { if !$0 { viewModel.skillBatchActionMessage = nil } }
            )) {
                Button(LanguageStore.shared.t("common.ok")) { viewModel.skillBatchActionMessage = nil }
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
                AppLoadingView(languageStore.t("skills.loading"))
                    .appDebugLayout("Skills.libraryLoading", logger: Self.layoutLog)
            }
        } detail: {
            if viewModel.hasCompletedInitialRefresh {
                AppPage(
                    selectedWarning?.title ?? skillDetailTitle,
                    subtitle: selectedWarning?.subtitle ?? skillDetailSubtitle,
                    constrainsContentToViewport: true
                ) {
                    skillDetailContent
                }
                .appDebugLayout("Skills.detail selected=\(selectedSkill?.name ?? selectedWarning?.title ?? "nil")", logger: Self.layoutLog)
            } else {
                AppLoadingView(languageStore.t("skills.loadingDetail"))
                    .appDebugLayout("Skills.detailLoading", logger: Self.layoutLog)
            }
        }
        .appDebugLayout("Skills.hsplit", logger: Self.layoutLog)
        .onAppear {
            #if DEBUG
            Self.layoutLog.debug("Skills.state event=appear selectedIDs=\(selectedSkillIDs.count, privacy: .public) selected=\(selectedSkill?.name ?? "nil", privacy: .public)")
            #endif
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.visibleSkillRecordsRevision) { _, _ in
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
        // Catches repository sync / update-check results (hasKnownUpdate) and
        // collection changes, which change row badges without touching skill records.
        .onChange(of: viewModel.appSettings.importedSkillRepositories) { _, _ in
            cachedLayout = recomputeLayout()
        }
        .onChange(of: viewModel.appSettings.skillCollections) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.selectedSkillID) { _, _ in scheduleSelectionSynchronization() }
        .onChange(of: selectedSkillIDs) { _, ids in
            skillUpdateStatusMessage = nil
            if !ids.isEmpty {
                selectedWarning = nil
                selectedCollectionID = nil
            }
            // The view model tracks a single focused skill (toolbar title,
            // cross-view state); a multi-selection has no single focus.
            let primary: SkillRecord.ID? = ids.count == 1 ? ids.first : nil
            if viewModel.selectedSkillID != primary {
                viewModel.selectedSkillID = primary
            }
            syncLibrarySelectionFromState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewSkillRequested)) { _ in
            createNewSkill()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckManageSkillCollectionsRequested)) { _ in
            isCollectionSheetPresented = true
        }
    }

    private var skillsScreenWithSheets: some View {
        skillsScreenCore
        .sheet(isPresented: $isImportSheetPresented) {
            SkillImportSheet(viewModel: viewModel, isPresented: $isImportSheetPresented) { result in
                importSummaryMessage = importSummary(for: result)
            }
        }
        .sheet(isPresented: $isCollectionSheetPresented) {
            SkillCollectionEditorSheet(viewModel: viewModel) { collection in
                selectedWarning = nil
                selectedSkillIDs = []
                selectedCollectionID = collection.id
                syncLibrarySelectionFromState()
                cachedLayout = recomputeLayout()
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
                title: LanguageStore.shared.t("skills.rename"),
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
                    skillUpdateStatusMessage = LanguageStore.shared.t("skills.updatedLatest")
                }
            }
        }
        .sheet(item: $skillCompareContext) { context in
            SkillCompareSheet(
                context: context,
                isPresented: Binding(
                    get: { skillCompareContext != nil },
                    set: { if !$0 { skillCompareContext = nil } }
                )
            )
        }
        .sheet(item: $readOnlySkillPreview) { skill in
            SkillReadOnlyPreviewSheet(skill: skill)
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
                selection: .multi(Binding(
                    get: { selectedLibraryItemIDs },
                    set: { updateSelection(fromLibraryItemIDs: $0) }
                )),
                rowTint: { item in
                    if case let .skill(skill) = item {
                        let metadata = metadataByID[skill.id]
                        return (metadata?.hasWarnings ?? false) ? Color.orange.opacity(0.10) : nil
                    }
                    return nil
                }
            ) { item in
                switch item {
                case let .collection(collection):
                    collectionListRow(collection, members: layout.collectionMembersByID[collection.id] ?? [])
                case let .skill(skill):
                    skillListRow(
                        skill,
                        metadata: metadataByID[skill.id] ?? SkillListMetadata(isAssigned: false, hasWarnings: false, isActiveForCurrentProject: false, isImported: false),
                        inactive: layout.inactiveByID[skill.id]
                    )
                }
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
            Text(LanguageStore.shared.t("skills.warnings"))
                .font(AppTheme.Font.micro.weight(.semibold))
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
        sections: [AppListSection<SkillLibraryItem>],
        inactiveByID: [SkillRecord.ID: Bool],
        managedSkills: [SkillRecord],
        catalogSkills: [SkillRecord],
        repositoryBySkillID: [SkillRecord.ID: ImportedSkillRepository],
        collectionCountBySkillID: [SkillRecord.ID: Int],
        collectionMembersByID: [UUID: [SkillRecord]]
    ) {
        let allRecords = viewModel.allVisibleSkillRecords

        let grouped = Dictionary(grouping: allRecords, by: \.name)
        let preferred = grouped.values.compactMap(preferredSkillRecord)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let nameCounts = grouped.mapValues(\.count)
        // Normalize each preferred path/root once for this recomputation. Both
        // repository resolution and collection membership use these values.
        let standardizedPathsBySkillID: [SkillRecord.ID: (filePath: String, rootPath: String)] = Dictionary(
            uniqueKeysWithValues: preferred.map { skill in
                let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
                let rootPath = fileURL.lastPathComponent == "SKILL.md"
                    ? fileURL.deletingLastPathComponent().path
                    : fileURL.path
                return (skill.id, (fileURL.path, rootPath))
            }
        )

        // Repository membership for every listed skill, resolved once per
        // layout rebuild. `importedRepository(for:)` standardizes two URLs per
        // repo per call — running it per row per body eval made list renders
        // O(skills × repos) in URL allocations. Standardize each clone path
        // once, each skill path once, then it's plain prefix matching.
        let repositories = viewModel.appSettings.importedSkillRepositories
        let clonePathsByRepoID: [(repository: ImportedSkillRepository, clonePath: String)] = repositories.map {
            ($0, URL(fileURLWithPath: $0.clonePath, isDirectory: true).standardizedFileURL.path)
        }
        func repository(for skill: SkillRecord) -> ImportedSkillRepository? {
            guard !clonePathsByRepoID.isEmpty, let paths = standardizedPathsBySkillID[skill.id] else { return nil }
            return clonePathsByRepoID.first {
                paths.filePath == $0.clonePath || paths.filePath.hasPrefix($0.clonePath + "/")
            }?.repository
        }
        var repositoryBySkillID: [SkillRecord.ID: ImportedSkillRepository] = [:]
        for skill in preferred {
            if let repository = repository(for: skill) { repositoryBySkillID[skill.id] = repository }
        }

        let collections = viewModel.appSettings.skillCollections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let collectionRootPathSets = collections.map { Set($0.skillRootPaths) }
        var collectionCountBySkillID: [SkillRecord.ID: Int] = [:]
        var collectionMembersByID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, [SkillRecord]()) })
        // One skills × collections pass supplies both the row count and the
        // collection member lists. Appending in `preferred` order preserves the
        // former filtered-list ordering exactly.
        for skill in preferred {
            guard let paths = standardizedPathsBySkillID[skill.id] else { continue }
            for (index, collection) in collections.enumerated() {
                let rootPaths = collectionRootPathSets[index]
                let isMember = rootPaths.contains(paths.rootPath)
                    || rootPaths.contains(paths.filePath)
                    || (collection.skillNames.contains(skill.name) && nameCounts[skill.name] == 1)
                guard isMember else { continue }
                collectionCountBySkillID[skill.id, default: 0] += 1
                collectionMembersByID[collection.id, default: []].append(skill)
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let managed: [SkillRecord]
        if query.isEmpty {
            managed = preferred
        } else {
            managed = preferred.filter { skill in
                let baseMatches = viewModel.cachedSkillSearchHaystackByID[skill.id]?.contains(query) ?? false
                if baseMatches { return true }
                guard let repository = repositoryBySkillID[skill.id] else { return false }
                return repository.displayName.lowercased().contains(query)
                    || "\(repository.owner)/\(repository.repo)".lowercased().contains(query)
            }
        }

        // A row is visually active when the skill is Default, assigned to at
        // least one project, or assigned to at least one Deck agent. Dim only
        // skills that are present in the catalog but unused everywhere.
        let metadataByID = viewModel.cachedSkillMetadataByID
        func isAssignedSomewhere(_ skill: SkillRecord) -> Bool {
            metadataByID[skill.id]?.isVisuallyActive(
                isCollectionMember: (collectionCountBySkillID[skill.id] ?? 0) > 0
            ) ?? false
        }

        var sections: [AppListSection<SkillLibraryItem>] = []
        var inactiveByID: [SkillRecord.ID: Bool] = [:]

        func mark(_ items: [SkillRecord], inactive: Bool) {
            for item in items { inactiveByID[item.id] = inactive }
        }

        let global = managed.filter { viewModel.skillIsEnabledGlobally($0) }
        let unassigned = managed.filter { !viewModel.skillIsEnabledGlobally($0) && (collectionCountBySkillID[$0.id] ?? 0) == 0 }
        let builtin = unassigned.filter { $0.source.kind == .builtin }
        let catalog = unassigned.filter { $0.source.kind != .builtin }
        mark(global, inactive: false)
        if !collections.isEmpty {
            let filteredCollections: [SkillCollectionRecord]
            if query.isEmpty {
                filteredCollections = collections
            } else {
                filteredCollections = collections.filter { collection in
                    let members = collectionMembersByID[collection.id] ?? []
                    return [collection.name, collection.description ?? "", collection.sourceLabel ?? ""].contains { $0.lowercased().contains(query) }
                        || members.contains { $0.name.lowercased().contains(query) }
                }
            }
            sections.append(AppListSection(
                id: "collections",
                title: LanguageStore.shared.t("skills.section.collections"),
                info: LanguageStore.shared.t("skills.section.collections.info"),
                items: filteredCollections.map { .collection($0) },
                emptyMessage: LanguageStore.shared.t("skills.section.collections.empty")
            ))
        }

        sections.append(AppListSection(
            id: "global",
            title: LanguageStore.shared.t("skills.section.default"),
            info: LanguageStore.shared.t("skills.section.default.info"),
            items: global.map { .skill($0) },
            emptyMessage: LanguageStore.shared.t("skills.section.default.empty")
        ))
        if !builtin.isEmpty {
            for item in builtin { inactiveByID[item.id] = !isAssignedSomewhere(item) }
            sections.append(AppListSection(
                id: "builtin",
                title: LanguageStore.shared.t("skills.section.builtin"),
                info: LanguageStore.shared.t("skills.section.builtin.info"),
                items: builtin.map { .skill($0) }
            ))
        }
        if !catalog.isEmpty {
            for item in catalog { inactiveByID[item.id] = !isAssignedSomewhere(item) }
            sections.append(AppListSection(
                id: "catalog",
                title: LanguageStore.shared.t("skills.section.catalog"),
                info: LanguageStore.shared.t("skills.section.catalog.info"),
                items: catalog.map { .skill($0) }
            ))
        }

        return (sections, inactiveByID, managed, preferred, repositoryBySkillID, collectionCountBySkillID, collectionMembersByID)
    }

    /// Selection-aware list context menu. A single right-clicked skill gets the
    /// full action set; a multi-selection gets a batch delete.
    ///
    /// `metadataByID` carries the cached `isImported` flag so this builder —
    /// which SwiftUI re-evaluates during layout for every visible row, not
    /// only when the menu opens — never calls `viewModel.isImportedSkill`
    /// (an `lstat` syscall) on the main thread while scrolling.
    @ViewBuilder
    private func skillContextMenu(
        for ids: Set<SkillRecord.ID>,
        metadataByID: [SkillRecord.ID: SkillListMetadata]
    ) -> some View {
        let skills = managedSkills.filter { ids.contains($0.id) }
        if skills.count > 1 {
            let importable = skills.filter { metadataByID[$0.id]?.isImported ?? false }
            let deletable = skills.filter { viewModel.canDeleteSkill($0) }
            if !importable.isEmpty {
                Button {
                    skillsPendingBatchRemoval = importable
                } label: {
                    Label(LanguageStore.shared.t("skills.alert.removeManyAction", importable.count), systemImage: "minus.circle")
                }
            }
            if !deletable.isEmpty {
                Button(role: .destructive) {
                    skillsPendingBatchDeletion = deletable
                } label: {
                    Label(LanguageStore.shared.t("skills.alert.moveManyTrash", deletable.count), systemImage: "trash")
                }
            }
        } else if let skill = skills.first {
            Button {
                skillEditTarget = makeSkillEditTarget(skill)
            } label: {
                Label(LanguageStore.shared.t("skills.editSkillMd"), systemImage: "square.and.pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            Button {
                revealSkillInFinder(skill)
            } label: {
                Label(LanguageStore.shared.t("skills.revealFinder"), systemImage: "finder")
            }

            Button {
                skillPendingRename = skill
            } label: {
                Label(LanguageStore.shared.t("skills.rename"), systemImage: "pencil")
            }
            .disabled(!viewModel.canRenameSkill(skill))

            if skill.source.kind == .builtin {
                Divider()
                if viewModel.bundledSkillIsDisabled(skill) {
                    Button {
                        viewModel.setBundledSkillDisabled(false, for: skill)
                    } label: {
                        Label(LanguageStore.shared.t("skills.enable"), systemImage: "checkmark.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        viewModel.setBundledSkillDisabled(true, for: skill)
                    } label: {
                        Label(LanguageStore.shared.t("skills.disable"), systemImage: "nosign")
                    }
                }
            }

            let isImported = metadataByID[skill.id]?.isImported ?? viewModel.isImportedSkill(skill)
            if isImported || viewModel.canDeleteSkill(skill) {
                Divider()
            }

            if isImported {
                Button {
                    skillPendingRemoval = skill
                } label: {
                    Label(LanguageStore.shared.t("skills.removeFromCatalog"), systemImage: "minus.circle")
                }
            }

            if viewModel.canDeleteSkill(skill) {
                Button(role: .destructive) {
                    skillPendingDeletion = skill
                } label: {
                    Label(LanguageStore.shared.t("skills.deleteSkill"), systemImage: "trash")
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
                Text(LanguageStore.shared.t("skills.referencedBy", warning.agentName, warning.project.name))
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
            .help(LanguageStore.shared.t("skills.resolveMissing"))
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .simultaneousGesture(TapGesture().onEnded { selectMissingSkillWarning(warning) })
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Resolve missing skill \(warning.missingSkill)")
        .accessibilityAction { selectMissingSkillWarning(warning) }
        .focusable()
        .onKeyPress(.space) {
            selectMissingSkillWarning(warning)
            return .handled
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
            selectDiagnosticWarning(warning)
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
        .background(hoveredWarningID == warning.id ? .orange.opacity(0.16) : .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hoveredWarningID == warning.id ? .orange.opacity(0.45) : .orange.opacity(0.25), lineWidth: 1))
        .animation(.easeInOut(duration: 0.15), value: hoveredWarningID == warning.id)
        .onHover { hovering in
            hoveredWarningID = hovering ? warning.id : nil
        }
    }

    private func selectDiagnosticWarning(_ warning: DiagnosticWarning) {
        selectedSkillIDs = []
        selectedWarning = .diagnostic(warning)
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let selectedWarning {
            skillWarningDetail(selectedWarning)
        } else if let collection = selectedCollection {
            collectionDetailContent(collection)
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

            AppCard(title: LanguageStore.shared.t("skills.projectAssignment")) {
                projectAssignmentList(for: skill)
            }

            AppCard(title: LanguageStore.shared.t("skills.agentAssignment")) {
                agentAssignmentList(for: skill)
            }

            LazyMarkdownCard(
                title: LanguageStore.shared.t("skills.definition"),
                source: skill.body,
                minimumHeight: 220,
                trailing: {
                    if viewModel.canRenameSkill(skill) {
                        Button {
                            skillEditTarget = makeSkillEditTarget(skill)
                        } label: {
                            Label(LanguageStore.shared.t("common.edit"), systemImage: "square.and.pencil")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .appSmallSecondaryButton()
                        .help(LanguageStore.shared.t("skills.editSkillMd"))
                    }
                }
            )

            if skill.source.kind == .package {
                AppCard(title: LanguageStore.shared.t("skills.packageSkill")) {
                    Text(LanguageStore.shared.t("skills.packageBody"))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if skill.source.kind == .builtin {
                AppCard(title: LanguageStore.shared.t("skills.disable")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.bundledSkillIsDisabled(skill)
                             ? LanguageStore.shared.t("skills.enableBuiltinHelp")
                             : LanguageStore.shared.t("skills.disableBuiltinHelp"))
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.bundledSkillIsDisabled(skill) {
                            Button(LanguageStore.shared.t("skills.enable")) {
                                viewModel.setBundledSkillDisabled(false, for: skill)
                            }
                            .appSecondaryButton()
                        } else {
                            Button(LanguageStore.shared.t("skills.disable"), role: .destructive) {
                                viewModel.setBundledSkillDisabled(true, for: skill)
                            }
                            .appDestructiveButton()
                        }
                    }
                }
            }

            if viewModel.isImportedSkill(skill) {
                AppCard(title: LanguageStore.shared.t("skills.removeSkill")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LanguageStore.shared.t("skills.removeBody", AppBrand.displayName))
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(LanguageStore.shared.t("skills.removeFromCatalog")) {
                            skillPendingRemoval = skill
                        }
                        .appSecondaryButton()
                    }
                }
            }

            if skill.source.kind != .builtin && viewModel.canDeleteSkill(skill) {
                AppCard(title: LanguageStore.shared.t("skills.deleteSkill")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LanguageStore.shared.t("skills.deleteBody"))
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(LanguageStore.shared.t("skills.deleteSkill"), role: .destructive) {
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

    private func collectionListRow(_ collection: SkillCollectionRecord, members: [SkillRecord]) -> some View {
        CollectionListRowView(
            collection: collection,
            memberCount: members.count,
            isAssigned: viewModel.skillCollectionIsEnabledGlobally(collection)
                || viewModel.enabledProjects.contains { viewModel.skillCollection(collection, isEnabledFor: $0) }
                || !viewModel.assignedAgents(for: collection).isEmpty,
            onEdit: { isCollectionSheetPresented = true }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                isCollectionSheetPresented = true
            } label: {
                Label(LanguageStore.shared.t("skills.manageCollections"), systemImage: "folder.badge.gearshape")
            }

            Divider()

            Button(role: .destructive) {
                collectionPendingDeletion = collection
            } label: {
                Label(LanguageStore.shared.t("skills.deleteCollection"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func collectionDetailContent(_ collection: SkillCollectionRecord) -> some View {
        let members = cachedLayout.collectionMembersByID[collection.id] ?? []
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(AppTheme.brandAccent)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(collection.name)
                            .font(.title3.weight(.semibold))
                            .fontWidth(.expanded)
                        Text(collection.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? collection.description! : "User-organized collection")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                    Button {
                        isCollectionSheetPresented = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    .appSecondaryButton()
                }
            }
        }

        syncedRepositoryCard(for: collection)

        AppCard(title: LanguageStore.shared.t("skills.projectAssignment")) {
            collectionAssignmentList(for: collection)
        }

        AppCard(title: LanguageStore.shared.t("skills.agentAssignment")) {
            collectionAgentAssignmentList(for: collection)
        }

        AppCard(title: LanguageStore.shared.t("skills.collectionMembership")) {
            collectionMembershipList(for: collection, members: members)
        }

        AppCard(title: LanguageStore.shared.t("skills.deleteCollection")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Delete this collection, or delete the collection and move its member skills to the Trash. Deleting only the collection keeps member skills in the catalog as standalone skills.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(LanguageStore.shared.t("skills.deleteCollection"), role: .destructive) {
                    collectionPendingDeletion = collection
                }
                .appDestructiveButton()
            }
        }
    }

    @ViewBuilder
    private func collectionMembershipList(for collection: SkillCollectionRecord, members: [SkillRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deactivate skills to keep them in this collection while excluding them from runtime loading. Use the row context menu to remove a skill from the collection without deleting its files.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if members.isEmpty {
                ContentUnavailableView(
                    "No Skills",
                    systemImage: "wand.and.stars",
                    description: Text(LanguageStore.shared.t("skills.collectionsEmpty"))
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(members) { skill in
                        collectionMembershipRow(skill, collection: collection)
                        if skill.id != members.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func collectionMembershipRow(_ skill: SkillRecord, collection: SkillCollectionRecord) -> some View {
        let repository = cachedLayout.repositoryBySkillID[skill.id]
        let isRuntimeIncluded = !viewModel.skillIsExcludedFromRuntime(skill, in: collection)
        return SkillListRowView(
            skill: skill,
            iconName: skillIcon(skill),
            iconColor: skillColor(isAssigned: viewModel.cachedSkillMetadataByID[skill.id]?.isAssigned ?? false),
            isInactive: !isRuntimeIncluded,
            isDisabled: viewModel.bundledSkillIsDisabled(skill),
            repositoryDisplayName: repository?.displayName,
            collectionCount: 0,
            hasUpdate: repository?.hasKnownUpdate == true,
            isUpdating: false,
            canRename: false,
            onUpdate: nil,
            onEdit: {},
            runtimeIncluded: isRuntimeIncluded,
            onRuntimeIncludedChange: { included in setSkill(skill, runtimeIncluded: included, in: collection) },
            onOpen: { readOnlySkillPreview = skill }
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                readOnlySkillPreview = skill
            } label: {
                Label("Open", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                selectedCollectionID = nil
                selectedSkillIDs = [skill.id]
                syncLibrarySelectionFromState()
            } label: {
                Label(LanguageStore.shared.t("skills.showDetails"), systemImage: "sidebar.right")
            }
            Divider()
            Button(role: .destructive) {
                removeSkillFromCollection(skill, collection: collection)
            } label: {
                Label(LanguageStore.shared.t("skills.removeFromCollection"), systemImage: "minus.circle")
            }
        }
    }

    private func removeSkillFromCollection(_ skill: SkillRecord, collection: SkillCollectionRecord) {
        var updated = collection
        let rootPath = viewModel.skillRootPath(forCollectionMembership: skill)
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        updated.skillRootPaths.remove(rootPath)
        updated.skillRootPaths.remove(filePath)
        updated.skillNames.remove(skill.name)
        updated.excludedSkillRootPaths.remove(rootPath)
        updated.excludedSkillRootPaths.remove(filePath)
        updated.excludedSkillNames.remove(skill.name)
        viewModel.saveSkillCollection(updated)
    }

    private func setSkill(_ skill: SkillRecord, runtimeIncluded: Bool, in collection: SkillCollectionRecord) {
        var updated = collection
        let rootPath = viewModel.skillRootPath(forCollectionMembership: skill)
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if runtimeIncluded {
            updated.excludedSkillRootPaths.remove(rootPath)
            updated.excludedSkillRootPaths.remove(filePath)
            updated.excludedSkillNames.remove(skill.name)
        } else {
            updated.excludedSkillRootPaths.insert(rootPath)
            updated.excludedSkillNames.insert(skill.name)
        }
        viewModel.saveSkillCollection(updated)
    }

    @ViewBuilder
    private func skillCollectionsCard(for skill: SkillRecord) -> some View {
        let collections = viewModel.skillCollections(containing: skill)
        if !collections.isEmpty {
            AppCard(title: LanguageStore.shared.t("skills.collections")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Collections expand to their skills at launch; Pi still receives one --skill argument per skill.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(collections) { collection in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Label(collection.name, systemImage: "folder.badge.gearshape")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(cachedLayout.collectionMembersByID[collection.id]?.count ?? 0) skills")
                                    .font(AppTheme.Font.micro.weight(.semibold))
                                    .foregroundStyle(AppTheme.mutedText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                                if let sourceLabel = collection.sourceLabel {
                                    Text(sourceLabel)
                                        .font(AppTheme.Font.micro)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            collectionAssignmentList(for: collection)
                        }
                        .padding(10)
                        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private func collectionAssignmentList(for collection: SkillCollectionRecord) -> some View {
        let isGlobal = viewModel.skillCollectionIsEnabledGlobally(collection)
        return LazyVStack(alignment: .leading, spacing: 0) {
            AllProjectsAssignmentRow(
                isOn: Binding(
                    get: { isGlobal },
                    set: { enabled in
                        if enabled { viewModel.enableSkillCollectionGlobally(collection) }
                        else { viewModel.disableSkillCollectionGlobally(collection) }
                    }
                ),
                subtitle: LanguageStore.shared.t("skills.enableCollectionEveryProject")
            )
            Divider()
            ForEach(viewModel.enabledProjects) { project in
                ProjectAssignmentToggleRow(
                    project: project,
                    isOn: Binding(
                        get: { isGlobal ? true : viewModel.skillCollection(collection, isEnabledFor: project) },
                        set: { enabled in viewModel.setSkillCollection(collection, enabled: enabled, for: project) }
                    )
                )
                .opacity(isGlobal ? 0.4 : 1)
                .allowsHitTesting(!isGlobal)
                if project.id != viewModel.enabledProjects.last?.id { Divider() }
            }
        }
    }

    private func collectionAgentAssignmentList(for collection: SkillCollectionRecord) -> some View {
        SkillCollectionAgentAssignmentList(
            viewModel: viewModel,
            collection: collection,
            presentError: { error, action in
                skillActionErrorMessage = "Could not \(action): \(error.localizedDescription)"
            }
        )
    }

    @ViewBuilder
    private func syncedRepositoryCard(for skill: SkillRecord) -> some View {
        if let repository = viewModel.importedRepository(for: skill) {
            syncedRepositoryCard(
                repository,
                description: "This skill is synced from a GitHub repository. You can edit it here; updates fast-forward and ask before overwriting your edits.",
                updateButtonTitle: LanguageStore.shared.t("skills.update")
            )
        }
    }

    @ViewBuilder
    private func syncedRepositoryCard(for collection: SkillCollectionRecord) -> some View {
        if let repository = viewModel.importedRepository(for: collection) {
            syncedRepositoryCard(
                repository,
                description: "This collection is synced from a GitHub repository. Updates refresh its repository-backed skills and ask before overwriting your edits.",
                updateButtonTitle: "Update Collection"
            )
        }
    }

    private func syncedRepositoryCard(
        _ repository: ImportedSkillRepository,
        description: String,
        updateButtonTitle: String
    ) -> some View {
        AppCard(title: LanguageStore.shared.t("skills.syncedRepo")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(description)
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
                            Text(LanguageStore.shared.t("skills.checkUpdates"))
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
                                Text(updateButtonTitle)
                            }
                        }
                        .appPrimaryButton()
                        .disabled(isCheckingSkillUpdate || isUpdatingSkillRepository)
                    }

                    if let webURL = repository.webURL {
                        Button(LanguageStore.shared.t("skills.openGitHub")) { NSWorkspace.shared.open(webURL) }
                            .appSecondaryButton()
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
                    skillUpdateStatusMessage = LanguageStore.shared.t("skills.updatedLatest")
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
        return AppCard(title: LanguageStore.shared.t("skills.missing")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(missingSkillExplanation(for: warning, candidate: candidate))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                AppKeyValueList(rows: missingSkillWarningRows(for: warning, candidate: candidate))

                VStack(alignment: .leading, spacing: 8) {
                    Text(LanguageStore.shared.t("skills.resolveHint"))
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
                        Button(LanguageStore.shared.t("skills.moveGlobal")) {
                            do {
                                try viewModel.moveSkillToGlobalCatalog(candidate)
                                selectedWarning = nil
                            } catch {
                                skillActionErrorMessage = error.localizedDescription
                            }
                        }
                        .appPrimaryButton()
                    }
                    Button(LanguageStore.shared.t("skills.searchCatalog")) {
                        searchText = warning.missingSkill
                    }
                    .appSecondaryButton()
                    Button(LanguageStore.shared.t("skills.import")) {
                        beginSkillImport()
                    }
                    .appSecondaryButton()
                    if let agentPath = sourcePath(forAgentNamed: warning.agentName, projectPath: warning.project.path) {
                        Button(LanguageStore.shared.t("skills.revealAgent")) {
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
        AppCard(title: LanguageStore.shared.t("skills.warningTitle")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(warning.message)
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let duplicate = duplicateSkillWarningDetails(warning) {
                    AppKeyValueList(rows: [
                        ("Skill", duplicate.name),
                        ("Issue", "Duplicate skill name")
                    ])

                    Text("Choose one canonical copy to keep. The other copies will be removed; project assignments, global defaults, and agent skills will stay with the kept copy.")
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    duplicateSkillResolutionList(for: duplicate)

                    HStack {
                        Button(LanguageStore.shared.t("skills.searchCatalog")) {
                            searchText = duplicate.name
                        }
                        ForEach(Array(duplicate.paths.enumerated()), id: \.offset) { index, path in
                            Button("Reveal Copy \(index + 1)") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                        if let compareContext = compareContext(for: duplicate) {
                            Button(LanguageStore.shared.t("skills.compare")) {
                                skillCompareContext = compareContext
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

    @ViewBuilder
    private func duplicateSkillResolutionList(for duplicate: (name: String, paths: [String])) -> some View {
        let records = duplicate.paths.compactMap { path in
            viewModel.allVisibleSkillRecords.first { $0.filePath == path }
        }

        if records.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(records) { skill in
                    let removed = records.filter { $0.id != skill.id }
                    let canKeep = SkillDuplicateResolution.canResolve(
                        keeping: skill,
                        removing: removed,
                        canDelete: viewModel.canDeleteSkill,
                        isImported: viewModel.isImportedSkill
                    )

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skillLocationLabel(skill, selectedProjectRoot: viewModel.globalCatalogSnapshot.projectRoot))
                                .font(.caption.weight(.semibold))
                                .fontWidth(.expanded)
                                .foregroundStyle(AppTheme.mutedText)
                            Text(skill.filePath)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if canKeep {
                            Button(LanguageStore.shared.t("skills.keepCopy")) {
                                skillPendingDuplicateResolution = (kept: skill, removed: removed)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else {
                            Text(LanguageStore.shared.t("skills.protected"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .help("This copy cannot be chosen because one or more other copies are bundled or package-managed and cannot be removed.")
                        }
                    }
                    .padding(10)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    /// Returns a compare context for the first two resolvable duplicate copies,
    /// or nil if fewer than two copies are currently visible.
    private func compareContext(for duplicate: (name: String, paths: [String])) -> SkillCompareContext? {
        let records = duplicate.paths.compactMap { path in
            viewModel.allVisibleSkillRecords.first { $0.filePath == path }
        }
        guard records.count >= 2 else { return nil }
        return SkillCompareContext(left: records[0], right: records[1])
    }

    private func skillWarningSummaryCard(warnings: [DiagnosticWarning]) -> some View {
        AppCard(title: LanguageStore.shared.t("skills.warnings")) {
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

    private var selectedCollection: SkillCollectionRecord? {
        guard selectedWarning == nil, let selectedCollectionID else { return nil }
        return viewModel.appSettings.skillCollections.first { $0.id == selectedCollectionID }
    }

    private var skillDetailTitle: String {
        if let selectedCollection { return selectedCollection.name }
        if selectedSkillIDs.count > 1 { return "\(selectedSkillIDs.count) Skills Selected" }
        return selectedSkill?.name ?? "Skill Details"
    }

    private var skillDetailSubtitle: String? {
        if let selectedCollection {
            let count = cachedLayout.collectionMembersByID[selectedCollection.id]?.count ?? 0
            return "Collection · \(count) skill\(count == 1 ? "" : "s")"
        }
        if selectedSkillIDs.count > 1 { return "Batch actions" }
        return selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.globalCatalogSnapshot.projectRoot) }
    }

    private func preferredSkillRecord(_ records: [SkillRecord]) -> SkillRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .legacyProject }
        ?? records.first
    }

    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        let validIDs = Set(managedSkills.map(\.id))
        let validCollectionIDs = Set(viewModel.appSettings.skillCollections.map(\.id))

        // Drop selections that no longer exist after a rescan.
        let pruned = selectedSkillIDs.intersection(validIDs)
        if pruned != selectedSkillIDs {
            selectedSkillIDs = pruned
        }
        if let selectedCollectionID, !validCollectionIDs.contains(selectedCollectionID) {
            self.selectedCollectionID = nil
        }

        // Adopt an external single-skill focus request (import, warning jump)
        // without clobbering a deliberate multi-selection.
        if let viewModelSkillID = viewModel.selectedSkillID, selectedSkillIDs.count <= 1, selectedCollectionID == nil {
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
        syncLibrarySelectionFromState()
    }

    private func ensureSelection() {
        guard selectedWarning == nil, selectedSkillIDs.isEmpty, selectedCollectionID == nil else { return }
        if let first = managedSkills.first {
            selectedSkillIDs = [first.id]
        }
    }

    private func updateSelection(fromLibraryItemIDs ids: Set<SkillLibraryItem.ID>) {
        selectedLibraryItemIDs = ids
        selectedWarning = nil
        let skillPrefix = "skill:"
        let collectionPrefix = "collection:"
        let skillIDs = Set(ids.compactMap { id -> SkillRecord.ID? in
            guard id.hasPrefix(skillPrefix) else { return nil }
            return String(id.dropFirst(skillPrefix.count))
        })
        if let collectionIDString = ids.first(where: { $0.hasPrefix(collectionPrefix) }).map({ String($0.dropFirst(collectionPrefix.count)) }),
           let collectionID = UUID(uuidString: collectionIDString) {
            selectedCollectionID = collectionID
            selectedSkillIDs = []
            viewModel.selectedSkillID = nil
        } else {
            selectedCollectionID = nil
            selectedSkillIDs = skillIDs
        }
        syncLibrarySelectionFromState()
    }

    private func syncLibrarySelectionFromState() {
        if let selectedCollectionID {
            selectedLibraryItemIDs = ["collection:\(selectedCollectionID.uuidString)"]
        } else {
            selectedLibraryItemIDs = Set(selectedSkillIDs.map { "skill:\($0)" })
        }
    }

    private func skillListRow(_ skill: SkillRecord, metadata: SkillListMetadata, inactive: Bool? = nil) -> some View {
        let collectionCount = cachedLayout.collectionCountBySkillID[skill.id] ?? 0
        let isActive: Bool
        let isInactive: Bool
        if let inactive {
            isInactive = inactive
            isActive = !inactive
        } else {
            isActive = metadata.isVisuallyActive(isCollectionMember: collectionCount > 0)
            isInactive = !isActive
        }
        let hasWarnings = metadata.hasWarnings
        let iconName = hasWarnings ? "exclamationmark.triangle.fill" : skillIcon(skill)
        let iconColor: Color = hasWarnings ? .orange : skillColor(isAssigned: isActive)
        let repository = cachedLayout.repositoryBySkillID[skill.id]
        let hasUpdate = repository?.hasKnownUpdate == true
        let canRename = viewModel.canRenameSkill(skill)
        return SkillListRowView(
            skill: skill,
            iconName: iconName,
            iconColor: iconColor,
            isInactive: isInactive,
            isDisabled: viewModel.bundledSkillIsDisabled(skill),
            repositoryDisplayName: repository?.displayName,
            collectionCount: collectionCount,
            hasUpdate: hasUpdate,
            isUpdating: repository != nil && isUpdatingSkillRepository,
            canRename: canRename,
            onUpdate: hasUpdate ? repository.map { repository in
                { applySkillRepositoryUpdate(repository) }
            } : nil,
            onEdit: { skillEditTarget = makeSkillEditTarget(skill) }
        )
        // Fill the row and give it a hit-testable shape so a right-click anywhere on the
        // row (not just on the name text) opens the context menu.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            // Selection-aware: a multi-selection that includes the right-
            // clicked row gets the batch actions; otherwise the right-clicked
            // row gets the single-skill action set. Mirrors the previous
            // `contextMenu(forSelectionType:)` semantics one-for-one.
            let effectiveIDs: Set<SkillRecord.ID> = (selectedSkillIDs.count > 1 && selectedSkillIDs.contains(skill.id))
                ? selectedSkillIDs
                : [skill.id]
            skillContextMenu(for: effectiveIDs, metadataByID: viewModel.cachedSkillMetadataByID)
        }
    }

    private func projectAssignmentList(for skill: SkillRecord) -> some View {
        let isGlobal = viewModel.skillIsEnabledGlobally(skill)
        return VStack(alignment: .leading, spacing: 10) {
            Text(LanguageStore.shared.t("skills.projectAssignmentHelp"))
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
                    subtitle: LanguageStore.shared.t("skills.enableEveryProject")
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
        // The warning is about a specific project's skill visibility, so resolve
        // the agent against that project's effective agents (not the selected
        // project). Keeps the Skills view global — no `selectedProjectPath` read.
        viewModel.startupSnapshot(forProjectPath: projectPath).effectiveAgents.first {
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
                        Text(LanguageStore.shared.t("skills.aiSummary"))
                            .font(.caption.weight(.semibold))
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        HStack(spacing: 6) {
                            AppSpinner().controlSize(.small)
                            Text(LanguageStore.shared.t("skills.summarising"))
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                case let .ready(text):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageStore.shared.t("skills.aiSummary"))
                            .font(.caption.weight(.semibold))
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        MarkdownDocumentView(source: text, minimumHeight: 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageStore.shared.t("skills.aiSummary"))
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
                AppSpinner().controlSize(.small)
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
            Button { beginSkillRename(for: skill) } label: {
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
            }
            .buttonStyle(.plain)
            .onHover { isSkillNameHovered = $0 }
            .help(viewModel.canRenameSkill(skill) ? "Rename skill" : "")
            .accessibilityLabel("Rename skill \(skill.name)")
            .disabled(!viewModel.canRenameSkill(skill))
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
        reportBatchSkillDeletionFailures(failed)
    }

    private func deleteCollectionOnly(_ collection: SkillCollectionRecord) {
        viewModel.removeSkillCollection(collection)
        collectionPendingDeletion = nil
        selectedCollectionID = nil
        syncLibrarySelectionFromState()
    }

    private func deleteCollectionAndMembers(_ collection: SkillCollectionRecord) {
        let members = cachedLayout.collectionMembersByID[collection.id] ?? []
        viewModel.removeSkillCollection(collection)
        let failed = viewModel.deleteSkills(members)
        collectionPendingDeletion = nil
        selectedCollectionID = nil
        selectedSkillIDs = []
        syncLibrarySelectionFromState()
        reportBatchSkillDeletionFailures(failed)
    }

    private func reportBatchSkillDeletionFailures(_ failed: [String]) {
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

    private func resolveDuplicateSkill(_ context: (kept: SkillRecord, removed: [SkillRecord])) {
        do {
            try viewModel.resolveSkillDuplicate(keeping: context.kept, removing: context.removed)
            skillPendingDuplicateResolution = nil
            selectedWarning = nil
        } catch {
            skillPendingDuplicateResolution = nil
            presentSkillActionError(error, skill: context.kept, action: "resolve the duplicate skill")
        }
    }

    @ViewBuilder
    private func batchSelectionDetail(_ skills: [SkillRecord]) -> some View {
        let deletable = skills.filter { viewModel.canDeleteSkill($0) }
        let importable = skills.filter { viewModel.isImportedSkill($0) }
        AppCard(title: LanguageStore.shared.t("skills.selectedCountCard", skills.count)) {
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
                                Text(LanguageStore.shared.t("skills.protected"))
                                    .font(AppTheme.Font.micro.weight(.semibold))
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
                    Text(LanguageStore.shared.t("skills.protectedBody"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private func makeSkillEditTarget(_ skill: SkillRecord) -> MarkdownFileEditTarget {
        MarkdownFileEditTarget(
            title: LanguageStore.shared.t("skills.editNamed", skill.name),
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
        let target = project.map { "project \($0.name) assignment" } ?? "global skills"
        let conflictPath = "~/.pi/agent/skills/\(skill.name) or an imported catalog path"
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

        return AppCheckboxRow(
            isOn: toggleBinding,
            accessibilityLabel: "Toggle agent \(agent.name)"
        ) {
            HStack(alignment: .center, spacing: 12) {
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
        }
        .controlSize(.regular)
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
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
/// agent array in local `@State` so sorting runs only when the snapshot or
/// selected skill changes, not on every detail-pane render.
private struct SkillAgentAssignmentList: View {
    let skill: SkillRecord
    let viewModel: AppViewModel
    let presentError: (Error, String) -> Void

    @State private var agents: [EffectiveAgentRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LanguageStore.shared.t("skills.agentAssignmentHelp"))
                .foregroundStyle(AppTheme.mutedText)

            AgentAssignmentSection(
                title: LanguageStore.shared.t("sidebar.agents"),
                agents: agents,
                viewModel: viewModel,
                isInactiveSection: false,
                emptyText: LanguageStore.shared.t("skills.noDeckAgents"),
                isAssigned: { agent in viewModel.skill(skill, isAssignedTo: agent) },
                setAssigned: { agent, enabled in
                    do { try viewModel.setSkill(skill, enabled: enabled, for: agent) }
                    catch { presentError(error, enabled ? "assign this skill to agent" : "remove this skill from agent") }
                }
            )
        }
        .onAppear { recompute() }
        .onChange(of: skill.id) { _, _ in recompute() }
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in recompute() }
    }

    private func recompute() {
        agents = viewModel.allDisplayAgents
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SkillCollectionAgentAssignmentList: View {
    let viewModel: AppViewModel
    let collection: SkillCollectionRecord
    let presentError: (Error, String) -> Void

    @State private var agents: [EffectiveAgentRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign this collection only to the selected Deck agents when they run. Parent Pi Agent sessions do not receive it from this setting.")
                .foregroundStyle(AppTheme.mutedText)

            AgentAssignmentSection(
                title: LanguageStore.shared.t("sidebar.agents"),
                agents: agents,
                viewModel: viewModel,
                isInactiveSection: false,
                emptyText: LanguageStore.shared.t("skills.noDeckAgents"),
                isAssigned: { agent in viewModel.skillCollection(collection, isAssignedTo: agent) },
                setAssigned: { agent, enabled in
                    do { try viewModel.setSkillCollection(collection, enabled: enabled, for: agent) }
                    catch { presentError(error, enabled ? "assign this collection to agent" : "remove this collection from agent") }
                }
            )
        }
        .onAppear { recompute() }
        .onChange(of: collection.id) { _, _ in recompute() }
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in recompute() }
    }

    private func recompute() {
        agents = viewModel.allDisplayAgents
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct AgentAssignmentSection: View {
    let title: String
    let agents: [EffectiveAgentRecord]
    let viewModel: AppViewModel
    let isInactiveSection: Bool
    let emptyText: String
    let isAssigned: (EffectiveAgentRecord) -> Bool
    let setAssigned: (EffectiveAgentRecord, Bool) -> Void

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
                                get: { isAssigned(agent) },
                                set: { enabled in setAssigned(agent, enabled) }
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
private struct CollectionListRowView: View {
    let collection: SkillCollectionRecord
    let memberCount: Int
    let isAssigned: Bool
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(isAssigned ? AppTheme.brandAccent : AppTheme.mutedText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(collection.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? collection.description! : "User-organized collection")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 10) {
                    if let sourceLabel = collection.sourceLabel {
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 11, height: 11)
                        Text(sourceLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Label("\(memberCount) skill\(memberCount == 1 ? "" : "s")", systemImage: "wand.and.stars")
                        .lineLimit(1)
                }
                .font(AppTheme.Font.micro)
                .foregroundStyle(AppTheme.mutedText)
                .help(collection.sourceLabel.map { "Synced from GitHub · \($0)" } ?? "Skill collection")
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if isHovered {
                Button(action: onEdit) {
                    Label(LanguageStore.shared.t("skills.editCollection"), systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                }
                .appSmallSecondaryButton()
                .help("Edit collection")
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.vertical, 5)
        .opacity(isAssigned ? 1 : 0.72)
    }
}

private struct SkillReadOnlyPreviewSheet: View {
    let skill: SkillRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                if let description = skill.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            MarkdownDocumentView(source: skill.body, minimumHeight: 320)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(LanguageStore.shared.t("common.done")) { dismiss() }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct SkillListRowView: View {
    let skill: SkillRecord
    let iconName: String
    let iconColor: Color
    let isInactive: Bool
    let isDisabled: Bool
    let repositoryDisplayName: String?
    let collectionCount: Int
    let hasUpdate: Bool
    let isUpdating: Bool
    let canRename: Bool
    let onUpdate: (() -> Void)?
    let onEdit: () -> Void
    var runtimeIncluded: Bool? = nil
    var onRuntimeIncludedChange: ((Bool) -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        let showsRowActions = isHovered || isUpdating
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(AppTheme.Font.sectionTitle)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .strikethrough(isDisabled, color: AppTheme.mutedText)
                    .lineLimit(1)
                Text(skill.description ?? "No description")
                    .font(AppTheme.Font.metadata)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if collectionCount > 0 || repositoryDisplayName != nil {
                    HStack(spacing: 6) {
                        if collectionCount > 0 {
                            Label("\(collectionCount) collection\(collectionCount == 1 ? "" : "s")", systemImage: "folder.badge.gearshape")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        if let repositoryDisplayName {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(width: 11, height: 11)
                            Text(repositoryDisplayName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(AppTheme.Font.micro)
                    .foregroundStyle(AppTheme.mutedText)
                    .help(repositoryDisplayName.map { "Synced from GitHub · \($0)" } ?? "Member of a skill collection")
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if showsRowActions {
                HStack(spacing: 6) {
                    if let runtimeIncluded, let onRuntimeIncludedChange {
                        Button {
                            onRuntimeIncludedChange(!runtimeIncluded)
                        } label: {
                            Label(
                                runtimeIncluded ? "Deactivate" : "Activate",
                                systemImage: runtimeIncluded ? "pause.circle" : "play.circle"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .appSmallSecondaryButton()
                        .help(runtimeIncluded ? "Deactivate for runtime loading" : "Activate for runtime loading")
                    }

                    if let onOpen {
                        Button(action: onOpen) {
                            Label("Open", systemImage: "doc.text.magnifyingglass")
                                .labelStyle(.titleAndIcon)
                        }
                        .appSmallSecondaryButton()
                        .help(LanguageStore.shared.t("skills.openReadonlyPreview"))
                    }

                    if let onUpdate {
                        Button(action: onUpdate) {
                            if isUpdating {
                                AppSpinner().controlSize(.small)
                            } else {
                                Label(LanguageStore.shared.t("skills.update"), systemImage: "arrow.down.circle")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .appSmallSecondaryButton()
                        .disabled(isUpdating)
                        .help(hasUpdate ? "Update available — sync this skill from GitHub" : "Sync this skill from GitHub")
                    }

                    if canRename {
                        Button(action: onEdit) {
                            Label(LanguageStore.shared.t("skills.editSkillMd"), systemImage: "square.and.pencil")
                                .labelStyle(.iconOnly)
                        }
                        .appSmallSecondaryButton()
                        .help(LanguageStore.shared.t("skills.editSkillMd"))
                    }
                }
                .fixedSize()
                .layoutPriority(2)
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.vertical, 5)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
    }
}

private struct SkillCollectionEditorSheet: View {
    var viewModel: AppViewModel
    var onSelect: (SkillCollectionRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedCollectionID: UUID?
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var selectedSkillIDs: Set<SkillRecord.ID> = []
    @State private var skillSearchText = ""
    @State private var pendingDelete: SkillCollectionRecord?
    @State private var originalSnapshot = CollectionDraftSnapshot.empty
    @State private var saveFeedbackToken: UUID?
    @State private var cachedCollections: [SkillCollectionRecord] = []
    @State private var cachedCatalogSkills: [SkillRecord] = []
    @State private var cachedFilteredCatalogSkills: [SkillRecord] = []
    @State private var cachedCollectionMemberCountsByID: [UUID: Int] = [:]
    @State private var cachedCollectionMemberIDsByID: [UUID: Set<SkillRecord.ID>] = [:]

    private struct CollectionDraftSnapshot: Equatable {
        var name: String
        var description: String?
        var skillIDs: Set<SkillRecord.ID>

        static let empty = CollectionDraftSnapshot(name: "", description: nil, skillIDs: [])
    }

    private var collections: [SkillCollectionRecord] { cachedCollections }

    private var selectedCollection: SkillCollectionRecord? {
        guard let selectedCollectionID else { return nil }
        return collections.first { $0.id == selectedCollectionID }
    }

    private var isSkillSearchActive: Bool {
        !skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentSnapshot: CollectionDraftSnapshot {
        CollectionDraftSnapshot(
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            description: normalizedDescription(draftDescription),
            skillIDs: selectedSkillIDs
        )
    }

    private var hasUnsavedChanges: Bool {
        currentSnapshot != originalSnapshot
    }

    private var canSave: Bool {
        !currentSnapshot.name.isEmpty && hasUnsavedChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                collectionSidebar
                    .frame(width: 230)
                Divider()
                editorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 620)
        .background(AppTheme.windowBackground)
        .onAppear {
            refreshCollectionEditorCaches()
            if let first = collections.first {
                load(first)
            } else {
                beginNewCollection()
            }
        }
        .onChange(of: skillSearchText) { _, _ in
            refreshFilteredCatalogSkills()
        }
        .onChange(of: viewModel.visibleSkillRecordsRevision) { _, _ in
            refreshCollectionEditorCaches()
            reloadSelectedCollectionIfNeeded()
        }
        .onChange(of: viewModel.appSettings.skillCollections) { _, _ in
            refreshCollectionEditorCaches()
            reloadSelectedCollectionIfNeeded()
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            refreshCollectionEditorCaches()
            reloadSelectedCollectionIfNeeded()
        }
        .alert(LanguageStore.shared.t("skills.alert.deleteCollection"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { collection in
            Button(LanguageStore.shared.t("common.delete"), role: .destructive) { delete(collection) }
            Button(LanguageStore.shared.t("common.cancel"), role: .cancel) { pendingDelete = nil }
        } message: { collection in
            Text("Delete \"\(collection.name)\" and clear its All Projects and project assignments? Skills remain in the catalog.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LanguageStore.shared.t("skills.collections"))
                .font(.headline)
                .fontWidth(.expanded)
            Text(LanguageStore.shared.t("skills.collectionsHelp"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var collectionSidebar: some View {
        let memberCountsByID = cachedCollectionMemberCountsByID
        return VStack(alignment: .leading, spacing: 0) {
            NewCollectionSidebarButton(action: beginNewCollection)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 6)

            AppList(
                sections: [AppListSection(
                    id: "collections",
                    title: LanguageStore.shared.t("skills.section.collections"),
                    items: collections,
                    emptyMessage: LanguageStore.shared.t("skills.noCollectionsYet")
                )],
                selection: .single(Binding(
                    get: { selectedCollectionID },
                    set: { id in
                        guard let id, let collection = collections.first(where: { $0.id == id }) else { return }
                        load(collection)
                    }
                )),
                bottomContentInset: 12
            ) { collection in
                collectionSidebarRowContent(collection, skillCount: memberCountsByID[collection.id] ?? 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.windowBackground)
    }

    private func collectionSidebarRowContent(_ collection: SkillCollectionRecord, skillCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(selectedCollectionID == collection.id ? AppTheme.brandAccent : AppTheme.mutedText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(skillCount) skill\(skillCount == 1 ? "" : "s")")
                    .font(AppTheme.Font.micro)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
        }
    }

    private struct NewCollectionSidebarButton: View {
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(AppTheme.brandAccent)
                        .frame(width: 18)
                    Text(LanguageStore.shared.t("skills.newCollection"))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppListMetrics.rowHorizontalPadding)
                .padding(.vertical, AppListMetrics.rowVerticalPadding + 1)
                .background {
                    RoundedRectangle(cornerRadius: AppListMetrics.cornerRadius, style: .continuous)
                        .fill(isHovering ? AppListMetrics.hoverFill : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: AppListMetrics.cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(LanguageStore.shared.t("skills.newCollection"))
        }
    }

    private var skillSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField("Search skills by name, description, source, or path", text: $skillSearchText)
                .textFieldStyle(.plain)
                .appBrandTint()
            if isSkillSearchActive {
                Button {
                    skillSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageStore.shared.t("skills.clearSearch"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
        )
    }

    private var editorContent: some View {
        let filteredSkills = cachedFilteredCatalogSkills
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                AppCard(title: selectedCollection == nil ? LanguageStore.shared.t("skills.newCollection") : LanguageStore.shared.t("skills.collectionTitle")) {
                    VStack(alignment: .leading, spacing: 12) {
                        AppTextField(text: $draftName, placeholder: LanguageStore.shared.t("skills.collectionName"))
                        AppTextField(text: $draftDescription, placeholder: LanguageStore.shared.t("loops.field.description"), axis: .vertical)
                            .lineLimit(2...4)
                        Text(LanguageStore.shared.t("skills.collectionBody"))
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AppCard(title: LanguageStore.shared.t("sidebar.skills")) {
                    VStack(alignment: .leading, spacing: 12) {
                        skillSearchField

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if filteredSkills.isEmpty {
                                    Text(isSkillSearchActive ? LanguageStore.shared.t("skills.noMatchSearch") : LanguageStore.shared.t("skills.noCatalogAvailable"))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .frame(maxWidth: .infinity, minHeight: 120)
                                }

                                ForEach(filteredSkills.indices, id: \.self) { index in
                                    let skill = filteredSkills[index]
                                    AppCheckboxRow(
                                        isOn: Binding(
                                            get: { selectedSkillIDs.contains(skill.id) },
                                            set: { enabled in
                                                if enabled { selectedSkillIDs.insert(skill.id) }
                                                else { selectedSkillIDs.remove(skill.id) }
                                            }
                                        ),
                                        accessibilityLabel: "Toggle skill \(skill.name)"
                                    ) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .font(.callout.weight(.semibold))
                                            Text(skill.description ?? skill.filePath)
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.mutedText)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 7)

                                    if index < filteredSkills.count - 1 { Divider() }
                                }
                            }
                        }
                        .frame(minHeight: 260)
                    }
                }
            }
            .padding(18)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let selectedCollection {
                Button(LanguageStore.shared.t("skills.deleteCollection"), role: .destructive) {
                    pendingDelete = selectedCollection
                }
                .appDestructiveButton()
            }
            Spacer(minLength: 0)
            Button(LanguageStore.shared.t("common.done")) { dismiss() }
                .appSecondaryButton()
                .keyboardShortcut(.cancelAction)
            Button { saveCollection() } label: {
                Label(saveFeedbackToken == nil ? "Save" : "Saved", systemImage: saveFeedbackToken == nil ? "tray.and.arrow.down" : "checkmark")
                    .contentTransition(.opacity)
                    .id(saveFeedbackToken == nil ? "save" : "saved")
            }
            .appPrimaryButton()
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .animation(.easeInOut(duration: 0.16), value: saveFeedbackToken)
        }
        .padding(16)
    }

    private func refreshCollectionEditorCaches() {
        cachedCollections = viewModel.appSettings.skillCollections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cachedCatalogSkills = dedupedSortedCatalogSkills(from: viewModel.allVisibleSkillRecords)
        cachedCollectionMemberIDsByID = viewModel.skillCollectionMemberIDsByCollectionID(
            for: cachedCollections,
            forProjectPath: viewModel.selectedProjectPath
        )
        cachedCollectionMemberCountsByID = cachedCollectionMemberIDsByID.mapValues(\.count)
        refreshFilteredCatalogSkills()
    }

    private func dedupedSortedCatalogSkills(from records: [SkillRecord]) -> [SkillRecord] {
        let grouped = Dictionary(grouping: records, by: \.name)
        return grouped.values.compactMap { records in
            records.first { $0.source.kind == .library }
            ?? records.first { $0.source.kind == .global }
            ?? records.first { $0.source.kind == .project }
            ?? records.first
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshFilteredCatalogSkills() {
        let query = skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            cachedFilteredCatalogSkills = cachedCatalogSkills
            return
        }
        cachedFilteredCatalogSkills = cachedCatalogSkills.filter { skill in
            [
                skill.name,
                skill.description ?? "",
                skill.source.displayName,
                skill.source.path,
                skill.filePath
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }

    private func cachedMemberIDs(for collection: SkillCollectionRecord) -> Set<SkillRecord.ID> {
        if let memberIDs = cachedCollectionMemberIDsByID[collection.id] {
            return memberIDs
        }
        return Set(viewModel.skillRecords(in: collection, forProjectPath: viewModel.selectedProjectPath).map(\.id))
    }

    private func reloadSelectedCollectionIfNeeded() {
        if let selectedCollectionID, let collection = collections.first(where: { $0.id == selectedCollectionID }) {
            load(collection)
        } else if selectedCollectionID != nil {
            beginNewCollection()
        }
    }

    private func beginNewCollection() {
        selectedCollectionID = nil
        draftName = ""
        draftDescription = ""
        selectedSkillIDs = []
        originalSnapshot = .empty
        saveFeedbackToken = nil
    }

    private func load(_ collection: SkillCollectionRecord) {
        selectedCollectionID = collection.id
        draftName = collection.name
        draftDescription = collection.description ?? ""
        let memberIDs = cachedMemberIDs(for: collection)
        selectedSkillIDs = memberIDs
        originalSnapshot = CollectionDraftSnapshot(
            name: collection.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: collection.description.flatMap(normalizedDescription),
            skillIDs: memberIDs
        )
        saveFeedbackToken = nil
    }

    private func saveCollection() {
        guard canSave else { return }
        let selectedSkills = cachedCatalogSkills.filter { selectedSkillIDs.contains($0.id) }
        let snapshot = currentSnapshot
        let collection = SkillCollectionRecord(
            id: selectedCollectionID ?? UUID(),
            name: snapshot.name,
            description: snapshot.description,
            skillRootPaths: Set(selectedSkills.map { viewModel.skillRootPath(forCollectionMembership: $0) }),
            skillNames: Set(selectedSkills.map(\.name)),
            importedRepositoryID: selectedCollection?.importedRepositoryID,
            sourceLabel: selectedCollection?.sourceLabel
        )
        viewModel.saveSkillCollection(collection)
        refreshCollectionEditorCaches()
        load(collection)
        onSelect(collection)
        showSavedFeedback()
    }

    private func normalizedDescription(_ description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func showSavedFeedback() {
        let token = UUID()
        withAnimation(.easeInOut(duration: 0.16)) {
            saveFeedbackToken = token
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard saveFeedbackToken == token else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                saveFeedbackToken = nil
            }
        }
    }

    private func delete(_ collection: SkillCollectionRecord) {
        viewModel.removeSkillCollection(collection)
        pendingDelete = nil
        refreshCollectionEditorCaches()
        if let first = collections.first(where: { $0.id != collection.id }) {
            load(first)
            onSelect(first)
        } else {
            beginNewCollection()
        }
    }
}
